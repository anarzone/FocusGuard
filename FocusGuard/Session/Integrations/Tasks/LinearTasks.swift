import Foundation

/// Linear issues assigned to the user that are started or not started yet,
/// through its GraphQL API with a sign-in (`LinearSignIn`) or a personal API key
/// (Linear › Settings › Security & access), kept in the Keychain. Done moves the
/// issue to its team's completed state; Undo moves it back to the state it was in.
final class LinearTasks: SignInTaskStore {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!

    static let issuesQuery = """
    query FocusGuardIssues {
      viewer {
        assignedIssues(first: 50, filter: { state: { type: { in: ["started", "unstarted"] } } }) {
          nodes { id identifier title dueDate createdAt state { id type } team { name } }
        }
      }
    }
    """

    /// The team's completed states; the first by position is where Done goes.
    static let doneStatesQuery = """
    query FocusGuardDoneStates($id: String!) {
      issue(id: $id) { team { states(filter: { type: { eq: "completed" } }) { nodes { id position } } } }
    }
    """

    static let moveMutation = """
    mutation FocusGuardMove($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) { success }
    }
    """

    static let viewerQuery = "query FocusGuardViewer { viewer { id } }"

    let source = TaskSource.linear
    private let credentials: TaskCredentials
    private let session: URLSession
    /// Telling Linear to drop a sign-in, after Disconnect; tests wait for it.
    private(set) var revoking: Task<Void, Never>?

    init(tokens: TokenStore = TaskTokens.keychain(for: .linear), signIn: RotatingTokens? = nil, session: URLSession = .shared) {
        self.credentials = TaskCredentials(personal: tokens, signIn: signIn)
        self.session = session
    }

    var hasToken: Bool { credentials.hasToken }
    var isSignedIn: Bool { credentials.isSignedIn }
    var wasSignedOut: Bool { credentials.wasSignedOut }

    func openTasks() async throws -> [TaskItem] {
        guard hasToken else { return [] }
        let data: IssuesData = try await send(Self.issuesQuery)
        return data.viewer.assignedIssues.nodes.compactMap(\.item)
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool {
        guard hasToken else { return false }
        do {
            let target: String?
            if completed {
                let states: DoneStatesData = try await send(Self.doneStatesQuery, variables: ["id": task.id])
                target = Self.doneState(in: states)
            } else {
                target = task.state
            }
            guard let target else { return false }
            let moved: MoveData = try await send(Self.moveMutation, variables: ["id": task.id, "stateId": target])
            return moved.issueUpdate.success
        } catch {
            return false
        }
    }

    func connect(token: String) async -> TokenCheck {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .rejected }
        do {
            let _: ViewerData = try await post(Self.viewerQuery, credential: .personal(key))
            credentials.personal.write(key)
            return .accepted
        } catch TaskSourceProblem.rejected {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    /// Clears the Keychain, and asks Linear to drop a sign-in.
    func disconnect() {
        let held = credentials.signIn?.read()
        credentials.forget()
        guard let held else { return }
        revoking = Task { [session] in
            for request in LinearOAuth.revokeRequests(held) {
                _ = try? await TaskWeb.exchange(request, session: session, staysOn: Self.isLinear)
            }
        }
    }

    /// One query with a token good to use now. A sign-in's token turned down is
    /// refreshed and the query tried once more.
    private func send<Payload: Decodable>(_ query: String, variables: [String: String] = [:]) async throws -> Payload {
        guard let credential = try await credentials.current() else { throw TaskSourceProblem.unreachable }
        do {
            return try await post(query, variables: variables, credential: credential)
        } catch TaskSourceProblem.rejected {
            guard let fresh = try await credentials.renewed(after: credential) else { throw TaskSourceProblem.rejected }
            return try await post(query, variables: variables, credential: fresh)
        }
    }

    private func post<Payload: Decodable>(_ query: String, variables: [String: String] = [:],
                                          credential: TaskCredential) async throws -> Payload {
        let (data, status) = try await TaskWeb.send(Self.request(query, variables: variables, credential: credential),
                                                    session: session, staysOn: Self.isLinear)
        return try Self.payload(Payload.self, from: data, status: status)
    }

    /// Tokens only ever go to Linear's API, over https.
    @Sendable static func isLinear(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == endpoint.host && url.port == nil
    }

    // MARK: - Requests

    static func request(_ query: String, variables: [String: String] = [:], key: String) -> URLRequest {
        request(query, variables: variables, credential: .personal(key))
    }

    /// A personal key goes in `Authorization` as it is, without "Bearer"; a
    /// sign-in's token goes with it.
    static func request(_ query: String, variables: [String: String] = [:], credential: TaskCredential) -> URLRequest {
        var post = URLRequest(url: endpoint, timeoutInterval: 15)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch credential {
        case .personal(let key):   post.setValue(key, forHTTPHeaderField: "Authorization")
        case .signedIn(let token): post.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        post.httpBody = try? JSONEncoder().encode(Body(query: query, variables: variables.isEmpty ? nil : variables))
        return post
    }

    struct Body: Codable, Equatable {
        let query: String
        let variables: [String: String]?
    }

    // MARK: - Responses

    struct Response<Payload: Decodable>: Decodable {
        let data: Payload?
        let errors: [GraphQLError]?
    }

    struct GraphQLError: Decodable {
        struct Extensions: Decodable {
            let type: String?
            let code: String?
        }

        let message: String?
        let extensions: Extensions?

        /// Linear's "authentication error": the key was turned down.
        var isAuthentication: Bool {
            extensions?.type == "authentication error" || extensions?.code == "AUTHENTICATION_ERROR"
        }
    }

    /// The data, or why not: 401 or an authentication error is a key turned
    /// down; anything else can't be reached now.
    static func payload<Payload: Decodable>(_ type: Payload.Type, from data: Data, status: Int) throws -> Payload {
        if status == 401 { throw TaskSourceProblem.rejected }
        let response = try? JSONDecoder().decode(Response<Payload>.self, from: data)
        if response?.errors?.contains(where: \.isAuthentication) == true { throw TaskSourceProblem.rejected }
        guard (200..<300).contains(status), response?.errors?.isEmpty != false, let result = response?.data else {
            throw TaskSourceProblem.unreachable
        }
        return result
    }

    struct IssuesData: Decodable {
        struct Viewer: Decodable {
            let assignedIssues: Connection<RawIssue>
        }

        let viewer: Viewer
    }

    struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node]
    }

    struct RawIssue: Decodable {
        struct State: Decodable {
            let id: String
            let type: String
        }

        struct Team: Decodable {
            let name: String
        }

        let id: String
        let identifier: String
        let title: String
        let dueDate: String?
        let createdAt: String?
        let state: State?
        let team: Team?

        /// "ENG-142 Fix login".
        var item: TaskItem? {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return TaskItem(source: .linear, id: id, title: identifier.isEmpty ? name : "\(identifier) \(name)",
                            list: team?.name ?? "", due: TaskDates.parse(dueDate), created: TaskDates.parse(createdAt),
                            started: state?.type == "started", state: state?.id)
        }
    }

    struct DoneStatesData: Decodable {
        struct Issue: Decodable {
            struct Team: Decodable {
                let states: Connection<DoneState>
            }

            let team: Team
        }

        let issue: Issue
    }

    struct DoneState: Decodable {
        let id: String
        let position: Double
    }

    static func doneState(in data: DoneStatesData) -> String? {
        data.issue.team.states.nodes.min { $0.position < $1.position }?.id
    }

    struct MoveData: Decodable {
        struct Update: Decodable {
            let success: Bool
        }

        let issueUpdate: Update
    }

    struct ViewerData: Decodable {
        struct Viewer: Decodable {
            let id: String
        }

        let viewer: Viewer
    }
}

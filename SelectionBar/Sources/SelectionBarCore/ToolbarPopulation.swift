import Foundation

public struct PopulationJob: Sendable {
  public var key: String
  public var record: ExtensionRecord
  public var action: ExtensionAction
  public init(key: String, record: ExtensionRecord, action: ExtensionAction) {
    self.key = key
    self.record = record
    self.action = action
  }
}

public struct PopulationState: Sendable {
  public var actions: [String: [[String: Value]]] = [:]
  public var errors: [String: String] = [:]
  public var pending: Set<String> = []
  public var order: [String] = []
  public var initial: [String: InitialCatalog] = [:]
  public init() {}
}
public struct InitialCatalog: Sendable {
  public var path: [Int]
  public var actions: [[String: Value]]
}

/// A selection owns its pure-population workers. Their response is useful only
/// for that generation, even when cancellation races a completed pipe read.
@MainActor
public final class ToolbarPopulation {
  public private(set) var generation = UUID()
  public var activeWorkerCount: Int { sessions.count }
  public var queuedWorkerCount: Int { queue.count }
  private let executable: String
  private let maximumConcurrent: Int
  private var sessions: [String: ScriptSession] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  private var queue: [PopulationJob] = []
  private var context = ActionContext(text: "")
  private var state = PopulationState()
  private var update: ((PopulationState) -> Void)?
  public init(executable: String, maximumConcurrent: Int = 2) {
    self.executable = executable
    self.maximumConcurrent = min(2, max(1, maximumConcurrent))
  }
  public func cancel() {
    generation = UUID()
    let workers = Array(sessions.values)
    let pending = Array(tasks.values)
    sessions.removeAll()
    tasks.removeAll()
    queue.removeAll()
    update = nil
    state = PopulationState()
    context = ActionContext(text: "")
    for worker in workers { worker.cancel() }
    for task in pending { task.cancel() }
  }
  public func populate(
    _ jobs: [PopulationJob], context: ActionContext,
    update: @escaping (PopulationState) -> Void
  ) {
    cancel()
    let token = generation
    var seen: Set<String> = []
    queue = jobs.filter { seen.insert($0.key).inserted }
    state.order = queue.map(\.key)
    state.pending = Set(state.order)
    self.context = context
    self.update = update
    update(state)
    launchQueued(token: token)
  }
  private func launchQueued(token: UUID) {
    guard generation == token else { return }
    while sessions.count < maximumConcurrent && !queue.isEmpty {
      let job = queue.removeFirst()
      let selection = context
      let worker = ScriptSession(executable: executable)
      sessions[job.key] = worker
      tasks[job.key] = Task { [weak self] in
        do {
          let response = try await worker.run(
            ScriptRequest(
              record: job.record,
              action: job.action, context: selection, phase: "population")
          ) { _ in
            throw LibraryError.invalid("Population cannot perform native actions")
          }
          guard let self, self.generation == token, !Task.isCancelled else { return }
          if let error = response.error {
            self.state.errors[job.key] = error
          } else {
            self.state.actions[job.key] = response.actions
            if let path = response.initialPath, let actions = response.initialActions {
              self.state.initial[job.key] = InitialCatalog(path: path, actions: actions)
            }
          }
          self.finished(job.key, token: token)
        } catch {
          guard let self, self.generation == token, !Task.isCancelled else { return }
          self.state.errors[job.key] = error.localizedDescription
          self.finished(job.key, token: token)
        }
      }
    }
  }
  private func finished(_ key: String, token: UUID) {
    guard generation == token else { return }
    state.pending.remove(key)
    sessions.removeValue(forKey: key)
    tasks.removeValue(forKey: key)
    update?(state)
    launchQueued(token: token)
  }
}

import AppKit
import LocalWorkflowKit
import SelectionBarCore
import SwiftUI

struct WorkflowSettingsView: View {
  @ObservedObject var store: SelectionWorkflowStore
  var directory: URL = WorkflowFiles.directory
  @State private var editing = TextRecipe(
    name: L10n.text("新配方"), steps: [.trim], destination: .copy)
  @State private var destinations: [NoteDestination] = []
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.text("文字配方")).font(.title3.bold())
      Text(L10n.text("按排列順序清理文字，再送到選定目的地。配方只在你按一下時執行。")).font(.caption).foregroundStyle(.secondary)
      List(store.recipes) { recipe in
        HStack {
          Button(recipe.name) { editing = recipe }.buttonStyle(.plain)
          Spacer()
          Text(L10n.text("%1$@ 步", String(describing: recipe.steps.count))).font(.caption)
            .foregroundStyle(.secondary)
          Button(role: .destructive) {
            store.remove(recipe.id)
          } label: {
            Image(systemName: "trash")
          }
        }
      }.frame(height: 110)
      TextField(L10n.text("配方名稱"), text: $editing.name).textFieldStyle(.roundedBorder)
      List(Array(editing.steps.enumerated()), id: \.offset) { index, step in
        HStack {
          Text("\(index + 1). " + step.title)
          Spacer()
          Button {
            editing.steps.swapAt(index, index - 1)
          } label: {
            Image(systemName: "chevron.up")
          }.disabled(index == 0)
          Button {
            editing.steps.remove(at: index)
          } label: {
            Image(systemName: "minus.circle")
          }
        }
      }.frame(height: 105)
      Menu(L10n.text("加入步驟")) {
        ForEach(CleanupStep.allCases) { step in Button(step.title) { editing.steps.append(step) } }
      }.disabled(editing.steps.count >= 12)
      Picker(L10n.text("最後一步"), selection: $editing.destination) {
        Text(L10n.text("複製")).tag(TextRecipe.Destination.copy)
        Text(L10n.text("貼回選區")).tag(TextRecipe.Destination.paste)
        Text(L10n.text("收藏到 EdgeNotes")).tag(TextRecipe.Destination.note)
      }.onChange(of: editing.destination) { _, value in
        if value != .note { editing.targetNoteID = nil }
      }
      if editing.destination == .note {
        Picker(L10n.text("目的筆記"), selection: $editing.targetNoteID) {
          Text(L10n.text("每次選擇資料夾／筆記")).tag(UUID?.none)
          ForEach(destinations) { note in
            Text(note.folderName + " › " + note.title).tag(Optional(note.id))
          }
          if let id = editing.targetNoteID, !destinations.contains(where: { $0.id == id }) {
            Text(L10n.text("目的筆記已不可用，執行時重新選擇")).tag(Optional(id))
          }
        }
      }
      if !store.error.isEmpty {
        Text(store.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        Button(L10n.text("新增配方")) {
          editing = TextRecipe(name: L10n.text("新配方"), steps: [.trim], destination: .copy)
        }
        Spacer()
        Button(L10n.text("儲存配方")) { store.save(editing) }.disabled(
          editing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Spacer(minLength: 0)
    }.padding(18).onAppear {
      destinations = (try? WorkflowFiles.destinations(in: directory).notes) ?? []
      if let first = store.recipes.first { editing = first }
    }
    .onReceive(
      DistributedNotificationCenter.default().publisher(for: WorkflowFiles.destinationsDidChange)
    ) { _ in destinations = (try? WorkflowFiles.destinations(in: directory).notes) ?? [] }
  }
}

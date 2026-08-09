import SwiftUI

struct AutomationView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedWorkflowID: UUID?
    @State private var selectedDeviceID: String?
    @State private var showingNewWorkflow = false

    private var selectedWorkflow: AutomationWorkflow? {
        model.workflows.first { $0.id == selectedWorkflowID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                List(model.workflows, selection: $selectedWorkflowID) { workflow in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workflow.name).fontWeight(.medium)
                        Text("\(workflow.steps.count) steps\(workflow.isBuiltIn ? " • built in" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(workflow.id)
                    .padding(.vertical, 4)
                }
                .frame(minWidth: 240, idealWidth: 280)

                if let workflow = selectedWorkflow {
                    workflowDetail(workflow)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    LabEmptyState(icon: "flowchart", title: "Select a workflow", message: "Choose a built-in or custom workflow.")
                }
            }
        }
        .sheet(isPresented: $showingNewWorkflow) {
            NewWorkflowSheet { name, actions in model.addWorkflow(name: name, actions: actions) }
        }
        .onAppear {
            selectedWorkflowID = selectedWorkflowID ?? model.workflows.first?.id
            selectedDeviceID = selectedDeviceID ?? model.devices.first?.id
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Automation Workflows").font(.title2.weight(.semibold))
                Text("Repeatable, cancellable sequences built on the VM and host-control adapters.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Workflow", systemImage: "plus") { showingNewWorkflow = true }
        }
        .padding(18)
    }

    private func workflowDetail(_ workflow: AutomationWorkflow) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workflow.name).font(.title2.weight(.semibold))
                    Text(workflow.isBuiltIn ? "Built-in workflow" : "Custom workflow")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !workflow.isBuiltIn {
                    Button("Delete", role: .destructive) { model.deleteWorkflow(workflow) }
                }
            }
            GroupBox("Steps") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                        HStack {
                            Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right.circle")
                            Text(step.action.displayName)
                            Spacer()
                            if let value = step.value { Text(value).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(.top, 6)
            }
            Picker("Target VM", selection: $selectedDeviceID) {
                Text("Choose a VM").tag(String?.none)
                ForEach(model.devices) { device in Text(device.name).tag(Optional(device.id)) }
            }
            Button("Run Workflow") {
                guard let id = selectedDeviceID,
                      let device = model.devices.first(where: { $0.id == id }) else { return }
                Task { await model.runWorkflow(workflow, on: device) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedDeviceID == nil || model.isBusy("workflow:\(workflow.id.uuidString)"))
            Spacer()
        }
        .padding(22)
    }
}

private struct NewWorkflowSheet: View {
    @Environment(\.dismiss) private var dismiss
    let create: (String, [AutomationAction]) -> Void
    @State private var name = ""
    @State private var actions: Set<AutomationAction> = [.screenshot, .diagnostics]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Automation Workflow").font(.title2.weight(.semibold))
            TextField("Workflow name", text: $name)
            Text("Steps execute in the order shown below.").font(.caption).foregroundStyle(.secondary)
            ForEach(AutomationAction.allCases) { action in
                Toggle(action.displayName, isOn: Binding(
                    get: { actions.contains(action) },
                    set: { enabled in
                        if enabled { actions.insert(action) } else { actions.remove(action) }
                    }
                ))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    create(name, AutomationAction.allCases.filter { actions.contains($0) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actions.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

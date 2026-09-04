import SwiftUI

struct AutomationView: View {
    @EnvironmentObject private var model: LabAppModel
    @State private var selectedWorkflowID: UUID?
    @State private var selectedDeviceID: String?
    @State private var showingNewWorkflow = false
    @State private var editingWorkflow: AutomationWorkflow?

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
                        Text("\(workflow.steps.count) steps\(workflow.isBuiltIn ? " • built in" : "")\(workflow.headless == true ? " • headless" : "")")
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
            WorkflowEditorSheet(workflow: nil) { name, steps, schedule, headless in
                model.addWorkflow(name: name, steps: steps, schedule: schedule, headless: headless)
            }
        }
        .sheet(item: $editingWorkflow) { workflow in
            WorkflowEditorSheet(workflow: workflow) { name, steps, schedule, headless in
                var updated = workflow
                updated.name = name
                updated.steps = steps
                updated.schedule = schedule
                updated.headless = headless
                model.updateWorkflow(updated)
            }
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
                Text("Ordered steps with values, delays, retries, conditions, scheduling metadata, and headless execution.")
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
                    Button("Edit") { editingWorkflow = workflow }
                    Button("Delete", role: .destructive) { model.deleteWorkflow(workflow) }
                }
            }
            HStack(spacing: 10) {
                if let schedule = workflow.schedule, !schedule.isEmpty {
                    StatusPill(text: "Schedule: \(schedule)", color: .blue)
                }
                if workflow.headless == true { StatusPill(text: "Headless", color: .purple) }
            }
            GroupBox("Steps") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top) {
                                Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right.circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.action.displayName)
                                    HStack(spacing: 8) {
                                        if let value = step.value, !value.isEmpty { Text("Value: \(value)") }
                                        if let delay = step.delaySeconds, delay > 0 { Text("Delay: \(delay.formatted())s") }
                                        if let retries = step.retryCount, retries > 0 { Text("Retries: \(retries)") }
                                        if let condition = step.condition, !condition.isEmpty { Text("If: \(condition)") }
                                        if step.continueOnFailure == true { Text("Continue on failure") }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.top, 6)
                .frame(maxHeight: 360)
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

private struct WorkflowEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String, [AutomationStep], String?, Bool) -> Void
    @State private var name: String
    @State private var steps: [AutomationStep]
    @State private var schedule: String
    @State private var headless: Bool

    init(
        workflow: AutomationWorkflow?,
        save: @escaping (String, [AutomationStep], String?, Bool) -> Void
    ) {
        self.save = save
        _name = State(initialValue: workflow?.name ?? "")
        _steps = State(initialValue: workflow?.steps ?? [
            AutomationStep(.boot),
            AutomationStep(.waitForGuest, value: "120"),
            AutomationStep(.screenshot),
            AutomationStep(.stop),
        ])
        _schedule = State(initialValue: workflow?.schedule ?? "")
        _headless = State(initialValue: workflow?.headless ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workflow Editor").font(.title2.weight(.semibold))
            HStack {
                TextField("Workflow name", text: $name)
                TextField("Schedule metadata (optional)", text: $schedule)
                Toggle("Headless", isOn: $headless).fixedSize()
            }
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(steps.indices, id: \.self) { index in
                        stepEditor(index)
                    }
                }
            }
            HStack {
                Button("Add Step", systemImage: "plus") { steps.append(AutomationStep(.delay, value: "1")) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    save(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        steps,
                        schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : schedule,
                        headless
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || steps.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 820, height: 680)
    }

    private func stepEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Picker("Action", selection: $steps[index].action) {
                    ForEach(AutomationAction.allCases) { action in Text(action.displayName).tag(action) }
                }
                TextField("Value / path / seconds", text: Binding(
                    get: { steps[index].value ?? "" },
                    set: { steps[index].value = $0.isEmpty ? nil : $0 }
                ))
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == steps.count - 1)
                Button(role: .destructive) { steps.remove(at: index) } label: { Image(systemName: "trash") }
            }
            HStack {
                Stepper(
                    "Delay \((steps[index].delaySeconds ?? 0).formatted())s",
                    value: Binding(
                        get: { steps[index].delaySeconds ?? 0 },
                        set: { steps[index].delaySeconds = $0 }
                    ),
                    in: 0...300,
                    step: 1
                )
                Stepper(
                    "Retries \(steps[index].retryCount ?? 0)",
                    value: Binding(
                        get: { steps[index].retryCount ?? 0 },
                        set: { steps[index].retryCount = $0 }
                    ),
                    in: 0...10
                )
                Picker("Condition", selection: Binding(
                    get: { steps[index].condition ?? "always" },
                    set: { steps[index].condition = $0 == "always" ? nil : $0 }
                )) {
                    Text("Always").tag("always")
                    Text("When running").tag("running")
                    Text("When stopped").tag("stopped")
                }
                Toggle("Continue on failure", isOn: Binding(
                    get: { steps[index].continueOnFailure ?? false },
                    set: { steps[index].continueOnFailure = $0 }
                ))
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard steps.indices.contains(destination) else { return }
        let step = steps.remove(at: index)
        steps.insert(step, at: destination)
    }
}

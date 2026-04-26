import SwiftUI
import UIKit

/// Manual quick-timer chip row + active countdown rows. Designed for
/// hands-in-the-pan use: tap a chip to start a 5/10/15/20-minute timer,
/// or tap Custom for a wheel picker. Multiple timers run concurrently.
/// At 0:00 we fire a warning haptic and the spoken-step service
/// announces "Timer done." — no audio asset needed for the chime.
struct CookingTimerChip: View {
    private static let quickMinutes = [5, 10, 15, 20]

    @State private var timers: [RunningTimer] = []
    @State private var firedTimerIDs: Set<UUID> = []
    @State private var showingCustomPicker = false
    @State private var customMinutes = 3

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            if !timers.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    VStack(spacing: SMSpacing.xs) {
                        ForEach(timers) { timer in
                            timerRow(timer: timer, now: context.date)
                        }
                    }
                }
            }

            HStack(spacing: SMSpacing.xs) {
                ForEach(Self.quickMinutes, id: \.self) { minutes in
                    Button {
                        startTimer(minutes: minutes)
                    } label: {
                        Text("\(minutes)m")
                            .font(SMFont.caption.weight(.semibold))
                            .foregroundStyle(SMColor.primary)
                            .padding(.horizontal, SMSpacing.md)
                            .padding(.vertical, SMSpacing.sm)
                            .background(SMColor.primary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showingCustomPicker = true
                } label: {
                    Label("Custom", systemImage: "timer")
                        .font(SMFont.caption.weight(.semibold))
                        .foregroundStyle(SMColor.textSecondary)
                        .padding(.horizontal, SMSpacing.md)
                        .padding(.vertical, SMSpacing.sm)
                        .background(SMColor.surfaceCard)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingCustomPicker) {
            customPickerSheet
        }
    }

    @ViewBuilder
    private func timerRow(timer: RunningTimer, now: Date) -> some View {
        let remaining = max(0, timer.deadline.timeIntervalSince(now))
        let isDone = remaining <= 0
        HStack(spacing: SMSpacing.sm) {
            Image(systemName: isDone ? "bell.fill" : "timer")
                .foregroundStyle(isDone ? SMColor.accent : SMColor.primary)
            Text(isDone ? "Timer done" : formatRemaining(remaining))
                .font(SMFont.subheadline.monospacedDigit())
                .foregroundStyle(SMColor.textPrimary)
            Text("(\(timer.label))")
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textTertiary)
            Spacer()
            Button {
                cancelTimer(timer.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(SMColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel timer")
        }
        .padding(.horizontal, SMSpacing.md)
        .padding(.vertical, SMSpacing.sm)
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
        .onAppear {
            checkForFire(timer: timer, now: now)
        }
        .onChange(of: now) { _, current in
            checkForFire(timer: timer, now: current)
        }
    }

    @ViewBuilder
    private var customPickerSheet: some View {
        NavigationStack {
            VStack(spacing: SMSpacing.lg) {
                Text("Set a custom timer")
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textSecondary)
                Picker("Minutes", selection: $customMinutes) {
                    ForEach(1..<121) { minute in
                        Text("\(minute) min").tag(minute)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                Button {
                    startTimer(minutes: customMinutes)
                    showingCustomPicker = false
                } label: {
                    Text("Start timer")
                        .font(SMFont.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SMSpacing.lg)
                        .background(SMColor.primary)
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(SMSpacing.xl)
            .background(SMColor.surface)
            .navigationTitle("Custom timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCustomPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func startTimer(minutes: Int) {
        let timer = RunningTimer(
            id: UUID(),
            label: "\(minutes) min",
            deadline: Date().addingTimeInterval(TimeInterval(minutes * 60))
        )
        timers.append(timer)
    }

    private func cancelTimer(_ id: UUID) {
        timers.removeAll { $0.id == id }
        firedTimerIDs.remove(id)
    }

    private func checkForFire(timer: RunningTimer, now: Date) {
        guard !firedTimerIDs.contains(timer.id) else { return }
        guard now >= timer.deadline else { return }
        firedTimerIDs.insert(timer.id)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        SpokenStepService.shared.speak("Timer done.")
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if let index = timers.firstIndex(where: { $0.id == timer.id }) {
                    timers.remove(at: index)
                }
                firedTimerIDs.remove(timer.id)
            }
        }
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

private struct RunningTimer: Identifiable, Hashable {
    let id: UUID
    let label: String
    let deadline: Date
}

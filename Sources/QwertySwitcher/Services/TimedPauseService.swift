import Foundation

final class TimedPauseService {
    private let prefsService: PreferencesService
    private let defaults: UserDefaults
    private let resumeKey = AppIdentity.keyPrefix + "autoSwitchResumeAt"
    private let schedulesTimers: Bool
    private var timer: Timer?
    private var isBroadcasting = false

    init(
        prefsService: PreferencesService,
        defaults: UserDefaults = .standard,
        schedulesTimers: Bool = true,
        now: Date = Date()
    ) {
        self.prefsService = prefsService
        self.defaults = defaults
        self.schedulesTimers = schedulesTimers
        NotificationCenter.default.addObserver(
            self, selector: #selector(autoSwitchChangedExternally),
            name: .autoSwitchToggled, object: nil
        )
        restore(now: now)
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    var resumeAt: Date? {
        let timestamp = defaults.double(forKey: resumeKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    var isActive: Bool { resumeAt != nil }

    func pause(for interval: TimeInterval, now: Date = Date()) {
        guard interval > 0 else { return }
        let date = now.addingTimeInterval(interval)
        defaults.set(date.timeIntervalSince1970, forKey: resumeKey)
        prefsService.isAutoSwitchEnabled = false
        scheduleResume(at: date)
        broadcastChange()
    }

    func resumeNow() {
        guard isActive else { return }
        clearSchedule()
        prefsService.isAutoSwitchEnabled = true
        broadcastChange()
    }

    /// Returns true only when an expired pause was resumed.
    @discardableResult
    func reconcile(now: Date = Date()) -> Bool {
        guard let date = resumeAt else { return false }
        guard date <= now else {
            prefsService.isAutoSwitchEnabled = false
            scheduleResume(at: date)
            return false
        }
        clearSchedule()
        prefsService.isAutoSwitchEnabled = true
        broadcastChange()
        return true
    }

    func cancelScheduledResume() {
        clearSchedule()
    }

    func resumeLabel(now: Date = Date()) -> String? {
        guard let date = resumeAt, date > now else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM, HH:mm"
        return "Пауза до \(formatter.string(from: date))"
    }

    private func restore(now: Date) {
        guard let date = resumeAt else { return }
        if date <= now {
            defaults.removeObject(forKey: resumeKey)
            prefsService.isAutoSwitchEnabled = true
        } else {
            prefsService.isAutoSwitchEnabled = false
            scheduleResume(at: date)
        }
    }

    private func scheduleResume(at date: Date) {
        timer?.invalidate()
        guard schedulesTimers else { return }
        let timer = Timer(fireAt: date, interval: 0, target: self,
                          selector: #selector(timerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func clearSchedule() {
        timer?.invalidate()
        timer = nil
        defaults.removeObject(forKey: resumeKey)
    }

    private func broadcastChange() {
        isBroadcasting = true
        NotificationCenter.default.post(name: .autoSwitchToggled, object: self)
        isBroadcasting = false
    }

    @objc private func timerFired() {
        _ = reconcile()
    }

    @objc private func autoSwitchChangedExternally() {
        guard !isBroadcasting, isActive else { return }
        clearSchedule()
    }
}

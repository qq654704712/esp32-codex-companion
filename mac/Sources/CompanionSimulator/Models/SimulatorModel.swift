import CodexCompanionCore
import Observation

@MainActor
@Observable
final class SimulatorModel {
    var deviceState: DeviceState = .working
    var fiveHourPercent = 68.0
    var weekPercent = 42.0
    var fiveHourAvailable = true
    var weekAvailable = true
    var stale = false
    var audioLevel = 0.45
    var promptOptions = ["允许一次", "在本次会话中允许", "拒绝"]
    var selectedOption = 0
}

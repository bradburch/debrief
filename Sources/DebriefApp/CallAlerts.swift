/// Seam over UNUserNotificationCenter so unit tests never construct it
/// (UNUserNotificationCenter.current() traps outside a bundled .app).
public protocol CallAlerting: AnyObject {
    func callDetected()
    func clear()
}

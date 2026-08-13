import XCTest
@testable import SpeedyFan

/// Read-only checks on the privileged-helper plumbing. Install/uninstall
/// are never exercised: they show an admin password prompt.
final class HelperTests: XCTestCase {

    func testInstalledPathIsTheBlessedLocation() {
        XCTAssertEqual(Helper.installedPath,
                       "/Library/PrivilegedHelperTools/com.speedyfan.fanctl")
    }

    func testIsInstalledMatchesFilesystemReality() {
        // Recompute the setuid-root condition independently and compare.
        var st = stat()
        let exists = stat(Helper.installedPath, &st) == 0
        let expected = exists && st.st_uid == 0 && (st.st_mode & S_ISUID) != 0
        XCTAssertEqual(Helper.isInstalled, expected)
    }

    func testBundledPathIfPresentIsExecutable() {
        // Under the test runner there is usually no bundled helper; the
        // contract is: nil, or a path to an executable file.
        if let path = Helper.bundledPath {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
            XCTAssertTrue(path.hasSuffix("fanctl"))
        }
    }

    func testHelperErrorsCarryUsefulMessages() {
        XCTAssertEqual(HelperError.bundledHelperMissing.errorDescription,
                       "Bundled fanctl helper not found")
        XCTAssertEqual(HelperError.installFailed("cancelled").errorDescription,
                       "Helper install failed: cancelled")
        XCTAssertEqual(HelperError.runFailed("boom").errorDescription, "boom")
    }
}

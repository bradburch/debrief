import XCTest
@testable import DebriefApp

final class KeychainStoreTests: XCTestCase {
    let testKey = "test-api-key-\(UUID().uuidString)"

    override func tearDown() { try? KeychainStore.delete(key: testKey) }

    func testSaveReadUpdateDelete() throws {
        XCTAssertNil(KeychainStore.read(key: testKey))
        try KeychainStore.save(key: testKey, value: "sk-ant-one")
        XCTAssertEqual(KeychainStore.read(key: testKey), "sk-ant-one")
        try KeychainStore.save(key: testKey, value: "sk-ant-two")  // overwrite
        XCTAssertEqual(KeychainStore.read(key: testKey), "sk-ant-two")
        try KeychainStore.delete(key: testKey)
        XCTAssertNil(KeychainStore.read(key: testKey))
    }
}

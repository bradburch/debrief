import XCTest
@testable import DebriefApp

final class SecretStoreTests: XCTestCase {
    let testKey = "test-api-key-\(UUID().uuidString)"

    override func tearDown() { try? SecretStore.delete(key: testKey) }

    func testSaveReadUpdateDelete() throws {
        XCTAssertNil(SecretStore.read(key: testKey))
        try SecretStore.save(key: testKey, value: "sk-ant-one")
        XCTAssertEqual(SecretStore.read(key: testKey), "sk-ant-one")
        try SecretStore.save(key: testKey, value: "sk-ant-two")  // overwrite
        XCTAssertEqual(SecretStore.read(key: testKey), "sk-ant-two")
        try SecretStore.delete(key: testKey)
        XCTAssertNil(SecretStore.read(key: testKey))
    }
}

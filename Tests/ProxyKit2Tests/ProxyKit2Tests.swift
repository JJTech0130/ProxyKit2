import XCTest
@testable import ProxyKit2

final class ProxyKit2Tests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        //XCTAssertEqual(ProxyKit2().text, "Hello, World!")
        let proxy = SOCKSServer(host: "127.0.0.1", port: 1080)
        try proxy.start()
        
        sleep(10)
        
        print("done")
    }
}

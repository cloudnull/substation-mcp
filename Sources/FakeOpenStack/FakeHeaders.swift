import Foundation
import HTTPTypes

/// Shared HTTP header name constants for the fake OpenStack services.
public enum FakeHeaders {
    public static let xAuthToken = HTTPField.Name("X-Auth-Token")!
    public static let xSubjectToken = HTTPField.Name("X-Subject-Token")!
    public static let xOpenStackNovaAPIVersion = HTTPField.Name("X-OpenStack-Nova-API-Version")!
}

import Foundation

/// Fetches, verifies and decodes the appcast feed. Pure network + parsing
/// layer — scheduling (`UpdatePolicy.shouldCheck`) and side effects on
/// preferences live in `UpdateController`.
final class UpdateFeedClient {
    enum FeedError: Error, Equatable {
        case badFeedURL
        case network(UpdateHTTPClient.ClientError)
        case malformedAppcastJSON
        case verification(UpdateManifestVerifier.VerificationError)
    }

    private let feedURLProvider: () -> String
    private let userAgent: String

    init(feedURLProvider: @escaping () -> String, userAgent: String) {
        self.feedURLProvider = feedURLProvider
        self.userAgent = userAgent
    }

    func fetchManifest(completion: @escaping (Result<UpdateManifest, FeedError>) -> Void) {
        let raw = feedURLProvider()
        guard UpdatePolicy.isAcceptableFeedURL(raw), let url = URL(string: raw) else {
            completion(.failure(.badFeedURL))
            return
        }
        let client = UpdateHTTPClient(userAgent: userAgent)
        client.fetch(url) { result in
            switch result {
            case .failure(let error):
                completion(.failure(.network(error)))
            case .success(let data):
                guard let appcast = try? JSONDecoder().decode(UpdateAppcast.self, from: data) else {
                    completion(.failure(.malformedAppcastJSON))
                    return
                }
                switch UpdateManifestVerifier.verify(appcast) {
                case .success(let manifest): completion(.success(manifest))
                case .failure(let error): completion(.failure(.verification(error)))
                }
            }
        }
    }
}

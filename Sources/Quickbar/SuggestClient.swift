import Foundation
import QuickbarCore

/// Fetches search suggestions for a template. One request in flight at a time;
/// a new keystroke cancels the previous request.
final class SuggestClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    private var task: URLSessionDataTask?
    private var cache: [String: [String]] = [:]

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// `completion` is called on the main thread, possibly synchronously from cache.
    func fetch(template: SearchTemplate, query: String, completion: @escaping ([String]) -> Void) {
        cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = template.suggestionURL(for: trimmed) else { return }
        let key = template.id + "\u{0}" + trimmed
        if let hit = cache[key] {
            completion(hit)
            return
        }
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let suggestions = Suggestions.parseOpenSearch(data)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.cache.count > 500 { self.cache.removeAll() }
                self.cache[key] = suggestions
                completion(suggestions)
            }
        }
        self.task = task
        task.resume()
    }
}

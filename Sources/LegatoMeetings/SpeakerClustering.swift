import Foundation

/// Groups voice embeddings (unit-length vectors, e.g. CAM++) into speakers: agglomerative clustering with average
/// linkage on cosine similarity. The vectors stay in memory; nothing here is saved.
public enum SpeakerClustering {
    /// Two groups whose average cosine similarity is at least this are one voice. An estimate for CAM++ on stretches of
    /// 1.5–10 s within one meeting (the research suggests starting at 0.5–0.6); calibrate with `legato meetings speakers`.
    public static let defaultThreshold: Float = 0.5

    /// A cluster label per embedding, `0..<k`, numbered in order of first appearance. Average linkage: two groups join
    /// while the mean similarity of their members is at least `threshold`.
    public static func agglomerate(_ embeddings: [[Float]], threshold: Float = defaultThreshold) -> [Int] {
        let n = embeddings.count
        guard n > 1 else { return [Int](repeating: 0, count: n) }
        // Similarity matrix, row-major; the diagonal is never a candidate.
        var similarity = [Float](repeating: -.infinity, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let s = dot(embeddings[i], embeddings[j])
                similarity[i * n + j] = s
                similarity[j * n + i] = s
            }
        }
        var size = [Int](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var parent = Array(0..<n)
        var best = [Int](repeating: -1, count: n)

        func refreshBest(_ i: Int) {
            var bestIndex = -1
            var bestValue = -Float.infinity
            let row = i * n
            for k in 0..<n where k != i && active[k] && similarity[row + k] > bestValue {
                bestValue = similarity[row + k]
                bestIndex = k
            }
            best[i] = bestIndex
        }
        for i in 0..<n { refreshBest(i) }

        while true {
            var a = -1
            var value = -Float.infinity
            for i in 0..<n where active[i] && best[i] >= 0 && similarity[i * n + best[i]] > value {
                value = similarity[i * n + best[i]]
                a = i
            }
            guard a >= 0, value >= threshold else { break }
            let b = best[a]
            // b joins a: Lance–Williams update for average linkage.
            let (sa, sb) = (Float(size[a]), Float(size[b]))
            for k in 0..<n where active[k] && k != a && k != b {
                let merged = (sa * similarity[a * n + k] + sb * similarity[b * n + k]) / (sa + sb)
                similarity[a * n + k] = merged
                similarity[k * n + a] = merged
            }
            active[b] = false
            parent[b] = a
            size[a] += size[b]
            refreshBest(a)
            for k in 0..<n where active[k] && k != a {
                if best[k] == a || best[k] == b {
                    refreshBest(k)
                } else if best[k] < 0 || similarity[k * n + a] > similarity[k * n + best[k]] {
                    best[k] = a
                }
            }
        }

        func root(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            return r
        }
        var labels: [Int: Int] = [:]
        return (0..<n).map { i in
            let r = root(i)
            if let label = labels[r] { return label }
            let label = labels.count
            labels[r] = label
            return label
        }
    }

    /// The unit-length mean of each cluster's embeddings, indexed by label.
    public static func centroids(_ embeddings: [[Float]], labels: [Int]) -> [[Float]] {
        let count = (labels.max() ?? -1) + 1
        guard count > 0, let dimension = embeddings.first?.count else { return [] }
        var sums = [[Float]](repeating: [Float](repeating: 0, count: dimension), count: count)
        for (vector, label) in zip(embeddings, labels) {
            for d in 0..<min(dimension, vector.count) { sums[label][d] += vector[d] }
        }
        return sums.map(normalized)
    }

    /// The label of the centroid most similar to `embedding`, skipping `excluded`; nil when none is left.
    public static func nearest(_ embedding: [Float], centroids: [[Float]], excluding excluded: Set<Int> = []) -> (label: Int, similarity: Float)? {
        var result: (label: Int, similarity: Float)?
        for (label, centroid) in centroids.enumerated() where !excluded.contains(label) {
            let s = dot(embedding, centroid)
            if result == nil || s > result!.similarity { result = (label, s) }
        }
        return result
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return v }
        return v.map { $0 / norm }
    }
}

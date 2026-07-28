import Foundation

/** Materializes an effective port (and optional host) into a ServerSpec for spawn
    and status: injects PORT / portEnv, substitutes `{port}` / `{host}` tokens, and
    rewrites derived url / heads / healthcheck URLs. Pure; unit-tested. */
public enum PortMaterializer {
    /** Apply `effectivePort` (and optional `effectiveHost`) to a committed/ad-hoc
        spec. `declaredPort` on status remains the pre-materialization `spec.port`.
        `matchHost` is the host already printed in committed urls/heads/healthcheck;
        when omitted, `spec.host` is used. Pass the pre-worktree host when the
        spawn path has already swapped `spec.host` to an ephemeral label. */
    public static func materialize(
        spec: ServerSpec, effectivePort: Int?, effectiveHost: String? = nil,
        matchHost: String? = nil
    ) -> ServerSpec {
        var next = spec
        let host = effectiveHost ?? spec.host
        if let host { next.host = host }
        if let effectivePort {
            next.port = effectivePort
            let envKey = spec.portEnv ?? "PORT"
            var env = next.env ?? [:]
            env[envKey] = String(effectivePort)
            if let host {
                env["DEVCTL_HOST"] = host
            }
            next.env = env
        }
        let portText = effectivePort.map(String.init)
        let hostText = host
        let previousHost = matchHost ?? spec.host
        next.command = next.command.map { substitute($0, port: portText, host: hostText) }
        if let url = next.url {
            next.url = rewriteURL(url, port: effectivePort, host: host, matchHost: previousHost)
                ?? substitute(url, port: portText, host: hostText)
        } else if let effectivePort, let host {
            next.url = "http://\(host):\(effectivePort)/"
        }
        if let heads = next.heads {
            var rewritten: [String: String] = [:]
            for (name, url) in heads {
                rewritten[name] =
                    rewriteURL(url, port: effectivePort, host: host, matchHost: previousHost)
                    ?? substitute(url, port: portText, host: hostText)
            }
            next.heads = rewritten
        }
        if var health = next.healthcheck {
            if let healthURL = health.url {
                health.url =
                    rewriteURL(healthURL, port: effectivePort, host: host, matchHost: previousHost)
                    ?? substitute(healthURL, port: portText, host: hostText)
            }
            if let effectivePort, health.port != nil {
                health.port = effectivePort
            }
            next.healthcheck = health
        }
        return next
    }

    /** Replace `{port}` / `{host}` tokens in a single string. */
    public static func substitute(_ text: String, port: String?, host: String?) -> String {
        var out = text
        if let port {
            out = out.replacingOccurrences(of: "{port}", with: port)
        }
        if let host {
            out = out.replacingOccurrences(of: "{host}", with: host)
        }
        return out
    }

    /** Prefer structured URL rewrite so an explicit committed URL follows the
        effective port/host without requiring `{port}` tokens. Host is only
        replaced when the URL's host exactly matches `matchHost` (so a head like
        `admin.app.localhost` keeps its subdomain when only the port moves). */
    public static func rewriteURL(
        _ raw: String, port: Int?, host: String?, matchHost: String? = nil
    ) -> String? {
        guard var components = URLComponents(string: raw) else { return nil }
        if let host {
            if let matchHost {
                if components.host == matchHost {
                    components.host = host
                }
            } else {
                components.host = host
            }
        }
        if let port { components.port = port }
        return components.string
    }
}

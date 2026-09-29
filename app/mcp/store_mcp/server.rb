# frozen_string_literal: true

module StoreMcp
  # MCP::Server, pinned to the newest protocol revision the installed SDK
  # actually implements (finding F12, eval/findings.yml).
  #
  # mcp 1.1.0 lists 2026-07-28 as its latest stable revision, and negotiates
  # it with any client that asks, but does not implement it. That revision
  # requires a `resultType` on list results, which 1.1.0 never sends; the SDK
  # added it in 1.2.0. A client that holds the server to the spec (Claude
  # Code 2.1.284 does) rejects tools/list and sees zero tools. The server
  # connects cleanly and exposes nothing.
  #
  # So the server does not claim a revision it cannot speak. Both of the
  # places 1.1.0 would reach 2026-07-28 are capped: `initialize` negotiates
  # down to PROTOCOL_VERSION, and `server/discover` lists only revisions up
  # to it. A client asking for 2026-07-28 falls back to 2025-11-25, which is
  # what the spec's version negotiation is for. Remove this class when the
  # SDK is upgraded to one that implements 2026-07-28 (1.2.0 or later).
  class Server < MCP::Server
    PROTOCOL_VERSION = "2025-11-25"
    SUPPORTED_PROTOCOL_VERSIONS =
      MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.select { |v| v <= PROTOCOL_VERSION }.freeze

    private

    def init(params, session: nil)
      requested = params[:protocolVersion]
      params = params.merge(protocolVersion: PROTOCOL_VERSION) unless SUPPORTED_PROTOCOL_VERSIONS.include?(requested)
      super
    end

    def discover(request)
      super.merge(supportedVersions: SUPPORTED_PROTOCOL_VERSIONS)
    end
  end
end

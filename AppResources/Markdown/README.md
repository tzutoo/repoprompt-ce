# Bundled Mermaid runtime

Chat and Agent Mode markdown render complete `mermaid` fences with this UMD bundle.

- Package: mermaid 10.9.3
- File: `mermaid.min.js`
- Source: https://cdn.jsdelivr.net/npm/mermaid@10.9.3/dist/mermaid.min.js
- SHA-256: `5a8ec91820bd55afef049068489369910e5d6ce70c8103952f27e29d3e76e8bc`
- License: MIT, copied at `ThirdPartyLicenses/mermaid/LICENSE`

Do not load Mermaid from the network at runtime. The renderer injects this local file into a non-persistent `WKWebView`.

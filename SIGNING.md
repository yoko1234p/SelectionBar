# Signing your build

Builds default to ad-hoc signing for local development. This source snapshot includes no developer certificate, private key, provisioning profile or personal signing configuration. Stable signing matters for macOS permissions and login items; rebuilding under another identity can require reauthorization. Public distribution requires your own signing/notarization setup.

To use your own identity, put its fingerprint in `SelectionBar/.local/signing-identity` (ignored by Git). The helper and host must use the same identity.


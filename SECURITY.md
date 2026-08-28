# Security

Do not commit cloud credentials, API keys, SSH private keys, presigned URLs, access/refresh tokens, QCOW2 images, runtime checkpoints or logs containing sensitive environment data.

The `.gitignore` blocks common sensitive artifacts, but operators are responsible for reviewing commits before pushing.

If a credential is accidentally committed, revoke/rotate it immediately and remove it from Git history before sharing the repository.

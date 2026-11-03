# Problem 4: Ship It Twice


## Assumptions

1. **There is no app code, so I did not write any.** I assume:
   - Backend: a Node app in `backend/` with `package.json` and `package-lock.json`, code in `src/`, started with `node src/server.js`, and `npm test` works.
   - The backend has `GET /healthz`. It returns JSON with `"version"` equal to the `RELEASE_SHA` environment variable. This is how the pipeline checks that the new version is running.
   - Frontend: `npm run build` creates `dist/` with `index.html` and files with hashed names in `dist/assets/`.
2. **`src/problem4` is treated as the repo root.** GitHub only runs workflows from the root `.github/` folder. In a real repo, move `.github/` to the root.
3. **AWS is already set up**:
   - EC2 servers with tags `App=api` and `Environment=staging` or `production`, behind a load balancer, with the SSM agent running.
   - S3 buckets and CloudFront for the frontend, and one S3 bucket for release files.
   - IAM roles for GitHub (OIDC): one to publish, one per environment to deploy.
4. **Two environments:** `staging`, then `production`. Production needs a person to approve. This is set in GitHub (Environments), not in the repo.
5. Everyone merges to `main` with pull requests. A push to `main` starts a release.

Settings needed in GitHub:
- Repository variables: `AWS_REGION`, `ARTIFACT_BUCKET`, `AWS_PUBLISH_ROLE_ARN`
- Environment variables: `AWS_DEPLOY_ROLE_ARN`, `API_URL`, `SITE_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID`, `SITE_URL`
- No secrets. AWS access uses OIDC, so there are no long-lived keys.

## How the pipelines work

```
pull request:  test only (no AWS access)
push to main:  test -> publish -> staging -> [approval] -> production
manual run:    deploy an old version again (rollback)
```

**Build once.** The test job builds one release file, named by the commit ID. It is saved in S3. Staging and production use the same file. Every deploy checks its checksum first.

**Backend deploy:**
1. Uses AWS SSM (no SSH). Deploys to **one server at a time** and stops at the first failure.
2. On each server: download, check checksum, switch to the new version, restart, and call `/healthz`. If the new version is not healthy, the server goes back to the old version by itself.
3. Then the pipeline tests the public URL. If it fails, it deploys the previous version again.

**Frontend deploy:**
1. Upload the hashed files first (cached for one year), then `version.json` and `index.html` last (never cached). Users never get an `index.html` that points to missing files.
2. Clear the CloudFront cache and wait for it.
3. Test that the site shows the new version. If not, deploy the previous version again.

## What "production ready" means here

| Need | What I did |
|---|---|
| No stored AWS keys | OIDC login. Pull requests have no AWS access. |
| Least access | Read-only by default. `id-token: write` only on jobs that use AWS. |
| Safe supply chain | Actions are pinned to a commit ID. Dependabot updates them. `npm audit` fails on high risk. |
| Same file everywhere | Build once, checksum before every deploy. |
| Safe promotion | Staging must pass first. Production needs approval. |
| Safe rollout | One server at a time, health check, automatic undo, final check on the public URL. |
| Easy rollback | Manual run with a commit ID. No rebuild. |
| No clashes | New pull request cancels the old test run. Two releases never run together. |
| Safe inputs | Commit ID and environment are checked before use. Values go into scripts as environment variables. |
| No hanging jobs | Every job has a timeout. |

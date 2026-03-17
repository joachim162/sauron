# Git Contribution Workflow (Clean PRs)
#git #workflow #github #contribution #forking

This workflow describes how to manage a repository where certain development/meta files (like `GEMINI.md` or the `knowledge/` directory) are valuable for the fork's context but must be excluded from official upstream Merge Requests (PRs).

## 1. The "Project-Full" Branch
Maintain your active development on a dedicated feature branch (e.g., `feature/rest_api`). This branch contains **everything**:
- Core implementation code.
- Documentation (`GEMINI.md`, `/knowledge`).
- Configuration files.

## 2. The "Surgical" PR Branch
When you are ready to submit your work to the upstream repository, create a clean, "surgical" branch that contains only the relevant implementation files.

### Step-by-Step Process:

1. **Update your local environment:**
   ```bash
   git checkout main
   git pull upstream main  # Get the latest official changes
   ```

2. **Create the clean PR branch:**
   ```bash
   git checkout -b pr/rest-api-clean
   ```

3. **Selectively bring in implementation files:**
   Use the `checkout` command with specific paths to copy files from your feature branch without bringing in the entire commit history or unwanted files.
   ```bash
   git checkout feature/rest_api -- sauron_api/ lib/ Sauron/
   ```

4. **Review and Commit:**
   Ensure only the intended files are staged.
   ```bash
   git status
   git commit -m "Implement Sauron REST API"
   ```

5. **Push and Open PR:**
   Push this clean branch to your fork and use it to open the PR to the upstream repository.
   ```bash
   git push origin pr/rest-api-clean
   ```

## Advantages
- **Professionalism:** Upstream maintainers only see the code they need to review.
- **Context Preservation:** Your fork remains a rich resource with all Zettelkasten notes and development guides intact.
- **Flexibility:** You can easily update the PR branch if requested changes are made on your feature branch.

## Related
- [[Running-the-API]]
- [[Environment-Setup]]

---
name: e2e-help
description: "Explain the E2E test loop technique and Playwright best practices"
---

# E2E Test Loop Help

Explain the following to the user:

## What is the E2E Test Loop?

An iterative loop for developing Playwright E2E tests:
1. Identify missing user flow coverage
2. Create page object if needed (`*.e2e.page.ts`)
3. Write ONE focused E2E test (`*.e2e.ts`)
4. Run tests to verify
5. **Run parallel reviews** (code-simplifier + Kieran reviewer in single message)
6. Commit and repeat

## Branch Setup

When starting on main/master, setup prompts to create a feature branch (`test/e2e-coverage`).

## File Naming Convention

- `*.e2e.page.ts` - Page objects (locators, setup, actions)
- `*.e2e.ts` - Test files (concise, use page objects)

Example:
```
e2e/
├── login.e2e.page.ts    # Page object
├── login.e2e.ts         # Tests
├── base.e2e.page.ts     # Base page object
```

## Commands

### `/e2e [OPTIONS]`

Start an E2E test development loop.

**Options:**
- `--max-iterations N` - Max iterations before auto-stop
- `--test-command "cmd"` - Override test command (default: `npx playwright test`)
- `--completion-promise "text"` - Custom promise phrase (default: E2E COMPLETE)

**Examples:**
```
/e2e --max-iterations 15
/e2e --test-command "pnpm test:e2e"
/e2e --completion-promise "ALL FLOWS COVERED" --max-iterations 20
```

### `/cancel-e2e`

Stop an active E2E loop.

## Page Object Pattern

Page objects encapsulate locators and actions:

```typescript
// login.e2e.page.ts
import { Page } from '@playwright/test';

export class LoginPage {
  constructor(private page: Page) {}

  // Locators
  emailInput = () => this.page.getByLabel('Email');
  passwordInput = () => this.page.getByLabel('Password');
  submitButton = () => this.page.getByRole('button', { name: 'Sign in' });

  // Navigation
  async goto() {
    await this.page.goto('/login');
  }

  // Actions
  async login(email: string, password: string) {
    await this.emailInput().fill(email);
    await this.passwordInput().fill(password);
    await this.submitButton().click();
  }
}
```

Tests become concise:

```typescript
// login.e2e.ts
import { test, expect } from '@playwright/test';
import { LoginPage } from './login.e2e.page';

test('user can login', async ({ page }) => {
  const loginPage = new LoginPage(page);
  await loginPage.goto();
  await loginPage.login('user@example.com', 'password');
  await expect(page).toHaveURL('/dashboard');
});
```

## Locator Priority

1. `getByRole()` - buttons, links, headings (most resilient)
2. `getByLabel()` - form inputs
3. `getByText()` - static text
4. `getByTestId()` - when semantic locators fail
5. **Avoid**: CSS selectors, XPath

## Authentication Pattern

Use setup projects for one-time auth:

```typescript
// auth.setup.ts
import { test as setup } from '@playwright/test';

setup('authenticate', async ({ page }) => {
  await page.goto('/login');
  // ... login steps
  await page.context().storageState({ path: 'playwright/.auth/user.json' });
});
```

In `playwright.config.ts`:
```typescript
projects: [
  { name: 'setup', testMatch: /.*\.setup\.ts/ },
  { name: 'chromium', dependencies: ['setup'], use: { storageState: 'playwright/.auth/user.json' } },
]
```

## Best Practices

- **Test user-visible behavior** - not implementation details
- **One flow per test** - keep tests focused
- **Tests must be independent** - no shared state
- **Web-first assertions** - `expect(locator).toBeVisible()` auto-waits
- **Mock external APIs** - use `page.route()` for third-party services

## Files Created

- `.claude/e2e-loop-<session>.local.md` - State file (iteration, config, prompt)
- `.claude/e2e-progress.txt` - Progress log (JSONL format)

## Stopping the Loop

The loop stops when:
- `<promise>E2E COMPLETE</promise>` is output
- `--max-iterations` is reached
- `/cancel-e2e` is run

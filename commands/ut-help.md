---
name: ut-help
description: "Explain the unit test loop technique"
---

# Unit Test Loop Help

Explain the following to the user:

## What is the Unit Test Loop?

It creates an iterative loop where Claude:
1. Runs coverage to find gaps
2. Writes ONE meaningful test per iteration
3. Commits with descriptive message
4. Repeats until target coverage reached

The key insight: **ONE test per iteration** forces focused, reviewable commits and prevents test spam.

## Philosophy

From Matt Pocock's approach:

> A great test covers behavior users depend on. It tests a feature that, if broken, would frustrate or block users. It validates real workflows - not implementation details.

**Do NOT** write tests just to increase coverage numbers. Use coverage as a guide to find UNTESTED USER-FACING BEHAVIOR.

If uncovered code isn't worth testing (boilerplate, unreachable branches, internal plumbing), use `/* v8 ignore */` comments instead.

## Commands

### `/ut [OPTIONS]`

Start a coverage improvement loop.

**Options:**
- `--target N%` - Target coverage percentage (exits when reached)
- `--max-iterations N` - Max iterations before auto-stop
- `--test-command "cmd"` - Override auto-detected coverage command
- `--completion-promise "text"` - Custom promise phrase (default: COVERAGE COMPLETE)

**Examples:**
```
/ut --target 80% --max-iterations 20
/ut --test-command "bun test:coverage"
/ut --completion-promise "ALL TESTS PASS" --max-iterations 10
```

### `/cancel-ut`

Stop an active loop and remove the state file.

## Auto-Detection

The loop automatically detects:

**Coverage tools (in order):**
1. `vitest.config.*` → `vitest run --coverage`
2. `jest.config.*` → `jest --coverage`
3. `c8` in package.json → `npx c8 <pm> test`
4. `nyc` in package.json → `npx nyc <pm> test`
5. `coverage` script → `<pm> run coverage`
6. `test:coverage` script → `<pm> run test:coverage`

**Package managers (by lockfile):**
1. `pnpm-lock.yaml` → pnpm
2. `bun.lockb` → bun
3. `yarn.lock` → yarn
4. default → npm

## Process Per Iteration

1. Run coverage command
2. Find files with low coverage
3. Read uncovered lines
4. Identify ONE important user-facing feature
5. Write ONE test for that feature
6. Run coverage again
7. Commit: `test(<file>): <describe behavior>`
8. Log to `.claude/ut-progress.txt`

## Stopping the Loop

The loop stops when:
- `<promise>YOUR_PROMISE</promise>` is output (default: COVERAGE COMPLETE)
- `--max-iterations` is reached
- `/cancel-ut` is run

## Files Created

- `.claude/ut-loop-<session>.local.md` - State file (iteration, config, prompt)
- `.claude/ut-progress.txt` - Progress log (JSONL format)

## React Testing Library Best Practices

> "The more your tests resemble the way your software is used, the more confidence they can give you."

### Query Priority (Official Order)

**Accessible to Everyone (prefer these):**
| Query | Use Case |
|-------|----------|
| `getByRole` | **Top preference** - use `name` option: `getByRole('button', {name: /submit/i})` |
| `getByLabelText` | Form fields - emulates how users find inputs |
| `getByPlaceholderText` | Only if no label exists |
| `getByText` | Non-interactive elements (div, span, p) |
| `getByDisplayValue` | Filled-in form values |

**Semantic Queries (less reliable):**
| Query | Use Case |
|-------|----------|
| `getByAltText` | img, area, input with alt |
| `getByTitle` | Not consistently read by screenreaders |

**Test IDs (last resort):**
| Query | Use Case |
|-------|----------|
| `getByTestId` | Only when role/text doesn't work |

### Query Type Selection

| Type | No Match | 1 Match | 1+ Match | Async |
|------|----------|---------|----------|-------|
| `getBy` | throw | return | throw | No |
| `queryBy` | null | return | throw | No |
| `findBy` | throw | return | throw | Yes |

**Rules:**
- `getBy`/`getAllBy` - default choice
- `queryBy`/`queryAllBy` - **only** for asserting absence
- `findBy`/`findAllBy` - async elements (returns Promise)

### userEvent (v14+)

**Setup pattern (recommended):**
```tsx
import userEvent from '@testing-library/user-event'

test('submits form', async () => {
  const user = userEvent.setup()
  render(<Form />)

  await user.type(screen.getByLabelText(/email/i), 'test@example.com')
  await user.click(screen.getByRole('button', {name: /submit/i}))

  expect(await screen.findByText(/success/i)).toBeInTheDocument()
})
```

**Available methods:**
- `user.click(element)` - click
- `user.dblClick(element)` - double click
- `user.type(element, text)` - type into input (clicks first)
- `user.keyboard('{Enter}')` - press keys
- `user.clear(element)` - clear input
- `user.selectOptions(select, ['value'])` - select dropdown
- `user.upload(input, file)` - file upload
- `user.tab()` - tab navigation
- `user.hover(element)` / `user.unhover(element)`

**Keyboard special keys:**
```tsx
await user.keyboard('{Enter}')           // press Enter
await user.keyboard('{Escape}')          // press Escape
await user.keyboard('{Shift>}A{/Shift}') // Shift+A
await user.keyboard('[ShiftLeft>]')      // hold Shift
```

### Best Practices

**Use `screen` object:**
```tsx
// Preferred
render(<Component />)
expect(screen.getByText(/hello/i)).toBeInTheDocument()

// Avoid (except for asFragment)
const { getByText } = render(<Component />)
```

**Use jest-dom matchers:**
```tsx
// Preferred
expect(button).toBeDisabled()
expect(element).toHaveClass('active')
expect(input).toHaveValue('text')

// Avoid
expect(button.disabled).toBe(true)
```

**Async testing:**
```tsx
// Use findBy for elements that appear async
const item = await screen.findByText(/loaded/i)

// Use waitFor for complex conditions
await waitFor(() =>
  expect(screen.getByText(/success/i)).toBeInTheDocument()
)
```

**Avoid manual `act()`:**
- RTL wraps `render` and events in `act()` automatically
- Exception: wrap `jest.advanceTimersByTime()` in `act()` with fake timers

**Resolving "not wrapped in act" warnings (in order):**
1. Use `findBy` query
2. Use `waitFor`
3. Mock the async operation
4. Wrap in `act()` (last resort)

### Mocking Patterns

**Callback props:**
```tsx
const onClick = jest.fn()
render(<Button onClick={onClick} />)
await user.click(screen.getByRole('button'))
expect(onClick).toHaveBeenCalledTimes(1)
```

**Child components:**
```tsx
jest.mock('./ChildComponent', () => () => <div>Mocked</div>)
```

**External APIs (MSW):**
```tsx
const server = setupServer(
  rest.get('/api/data', (req, res, ctx) => res(ctx.json({ data: 'mocked' })))
)
beforeAll(() => server.listen())
afterEach(() => server.resetHandlers())
afterAll(() => server.close())
```

### Test Organization

- Separate test file per exported component
- Use `describe()` only for grouping tests with shared setup
- Use `test()` outside `describe()`, `it()` inside
- Don't use snapshots for class assertions - use `toHaveClass()`

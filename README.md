# somto-dev-toolkit

Personal collection of Claude Code tools and skills.

## Installation

```
/plugin marketplace add SomtoUgeh/somto-dev-toolkit
/plugin install somto-dev-toolkit@somto-dev-toolkit
```

## Contents

### Skills

**blog-post-writer** - Transform brain dumps into polished blog posts with conversational, authentic tone. Includes voice guidelines, story circle framework, and technical storytelling patterns.

**technical-svg-diagrams** - Generate clean, minimal SVG diagrams in a consistent style. Supports architecture, flow, and component diagrams with built-in WebP export.

### Commands

**prd** - Deep interview to build comprehensive specs + PRD JSON for Ralph Wiggum-style iteration. Generates spec, PRD, and progress files, then copies ralph-loop command to clipboard.

```
/somto-dev-toolkit:prd "add user authentication"
/somto-dev-toolkit:prd ./plans/feature.md
/somto-dev-toolkit:prd ./specs/
```

Outputs:
- `plans/<feature>-spec.md` - comprehensive spec
- `plans/<feature>.prd.json` - user stories with pass/fail status
- `plans/<feature>.progress.txt` - iteration log (JSON lines)
- ralph-loop command copied to clipboard

## Updating

```
/plugin marketplace update
/plugin update somto-dev-toolkit@somto-dev-toolkit
```

## License

MIT

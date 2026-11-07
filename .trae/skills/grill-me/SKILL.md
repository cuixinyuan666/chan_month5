---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
license: MIT
metadata:
  derived_from: "https://github.com/mattpocock/skills/tree/main/skills/productivity/grill-me"
  original_author: "Matt Pocock (@mattpocock)"
  original_license: MIT
  version: 1.0.0
---


# Grill Me

> Derived from Matt Pocock grill-me (MIT). Interview discipline preserved verbatim.
> Source: https://github.com/alirezarezvani/claude-skills (engineering/grill-me), fetched 2026-10-02.
Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time.

If a question can be answered by exploring the codebase, explore the codebase instead.

## Rules

1. **One question per turn.** Never bundle.
2. **Provide a recommended answer with each question.** Defaulting to "what do you think?" is lazy.
3. **Explore the codebase before asking.** If grep / Read resolves it, do that first. Saves a turn.
4. **Walk the tree depth-first.** Finish a branch before opening another.
5. **Track dependencies.** If decision B depends on decision A, ask A first.

## Output Pattern

Q[i]/[total]: [question]
Recommended answer: [your call + 1-sentence rationale]

## 本工程约定

- 与 AGENTS.md「与提问者的交流」同向叠加：每个问题必须给出推荐答案，不允许只把问题丢回给用户。
- 与 AGENTS.md「确认执行门禁」同向：问到关键计算逻辑时，仍需文字方案 + 等用户确认，不得追问代替确认。

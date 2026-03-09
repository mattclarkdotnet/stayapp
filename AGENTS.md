# AGENTS.md

## Overview

Mac users who use multiple external monitors suffer from the problem that app windows always move to one screen when the system awakes from sleep.

Stay is a macOS utility that solves this problem by automatically moving app windows to the screen they were on before sleep.

As a macOS utility it must be lightweight, reliable, and easy to install.  It is focused on one simple task - ensuring windows are moved to the correct screen after sleep.

## Design documentation

Maintain a DESIGN.md file that documents the design decisions and architecture of the codebase.  Comment the codebase to show what design intent it supports and how.  When the code or the design changes, update the comments and DESIGN.md to reflect the current state.

Maintain a TESTING.md file that documents the testing strategy and tools used for the codebase.

For each test directory, maintain a TESTING.md file that documents how the specific test suite supports the overall testing strategy, and how edge cases are approached.

## Testing

Perfect testing will be difficult because it might require an actual sleep cycle to be tested.  Leave that level of testing to a QA engineer.

For automated testing focus on writing tests that can run without a sleep cycle.  Ensure the code is resilient to sleep or awake events that might arrive in unexpected orders or be repeated.

## Language and tooling
- use idiomatic Swift
- use xCode compatible project structure
- minimise the use of external dependencies
- target MacOS tahoe and above

## General design principles
- Use state machines
- Parse, don't validate at the edges
- Functional core, imperative shell
- Use types to define core concepts

---
name: Nim-generated Python
description: Constraints for constructing executable Python source from Nim string expressions.
---

When Nim constructs Python source by concatenating ordinary double-quoted strings, use single-quoted Python literals for generated Python keys, comparisons, and error messages.

**Why:** Nim's doubled-double-quote escaping becomes ambiguous around adjacent Python syntax and repeatedly produced compile errors in the generated validation program.

**How to apply:** Keep only the injected encoded values and unavoidable JSON syntax in Nim-escaped double quotes; write the generated Python itself with single-quoted literals where Python permits it.
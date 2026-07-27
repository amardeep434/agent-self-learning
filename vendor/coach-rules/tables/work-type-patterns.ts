const WORK_TYPE_PATTERNS: [RegExp, string][] = [
  [/\b(bug|fix|error|issue|crash|broken|wrong|fail|debug)\b/i, 'bug fix'],
  [/\b(refactor|clean ?up|rename|restructure|reorganize|simplify)\b/i, 'refactor'],
  [/\b(test|spec|coverage|assert|expect|mock|stub)\b/i, 'test'],
  [/\b(doc|readme|comment|jsdoc|typedoc|explain)\b/i, 'documentation'],
  [/\b(deploy|ci|cd|pipeline|docker|kubernetes|helm|terraform|infra)\b/i, 'devops'],
  [/\b(style|css|layout|design|ui|ux|theme|color|font)\b/i, 'styling'],
  [/\b(config|setup|install|init|bootstrap|scaffold)\b/i, 'configuration'],
  [/\b(perf|optim|speed|cache|memory|benchmark)\b/i, 'performance'],
  [/\b(security|auth|permission|encrypt|token|oauth|cors)\b/i, 'security'],
  [/\b(migration?|upgrade|update|version|deprecat)\b/i, 'migration'],
]

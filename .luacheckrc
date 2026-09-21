std = "lua51"
max_line_length = 120
exclude_files = { "tools/.cache/**", ".release/**" }
ignore = { "212/_.*" } -- unused args prefixed with _
files["tests/"] = { std = "+luajit", globals = { "arg" } }

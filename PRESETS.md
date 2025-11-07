# Vai Configuration and Presets

Vai supports a flexible configuration system with three levels of precedence and task aliases for quick access.

## Configuration Precedence (highest to lowest)

1. **Local config** (`./vai.toml`) - Project-specific configuration
2. **Activated presets** (`~/.config/vai/presets/*.toml`) - Conditional configurations
3. **Global config** (`~/.config/vai/vai.toml`) - User-wide defaults

When the same task is defined in multiple configs, the higher precedence config wins.

## Configuration Locations

### Global Configuration
- Path: `~/.config/vai/vai.toml`
- Purpose: Define tasks that are available in all projects
- Example: See `examples/global-config.toml`

### Presets
- Path: `~/.config/vai/presets/*.toml`
- Purpose: Define tasks that activate based on conditions (e.g., file presence)
- Example: See `examples/preset-docker.toml` and `examples/preset-node.toml`

### Local Configuration
- Path: `./vai.toml` (in project directory)
- Purpose: Project-specific tasks that override presets and global config
- Example: See `examples/local-config.toml`

## Task Aliases

Tasks can have short aliases for quicker access:

```toml
[tasks.build]
description = "Build the project"
command = "zig build"
alias = "b"
```

With this configuration, you can run either `vai build` or `vai b` to execute the same task.

### Alias Features
- Aliases are shown in the help output: `build (b): Build the project.`
- Aliases work exactly like the full command name
- Aliases support all the same arguments as the full command
- Each task can have one alias

## Preset Activation

Presets can be conditionally activated using the `[preset]` section:

### Available Conditions

#### `when_file`
Activates the preset when a specific file exists in the current working directory.

```toml
[preset]
when_file = "Dockerfile"

[tasks.build]
description = "Build docker image"
command = "docker build -t myapp ."
```

## Usage Examples

### Example 1: Docker Preset

Create `~/.config/vai/presets/docker.toml`:
```toml
[preset]
when_file = "Dockerfile"

[tasks.up]
description = "Start docker compose"
command = "docker compose up -d"

[tasks.down]
description = "Stop docker compose"
command = "docker compose down"
```

Now when you're in any directory with a `Dockerfile`, the `up` and `down` tasks will be available automatically.

### Example 2: Node.js Preset

Create `~/.config/vai/presets/node.toml`:
```toml
[preset]
when_file = "package.json"

[tasks.install]
description = "Install dependencies"
command = "npm install"

[tasks.dev]
description = "Start development server"
command = "npm run dev"
```

When you're in a Node.js project (with `package.json`), these tasks will be available.

### Example 3: Local Override

If you want to customize a task for a specific project, create a local `vai.toml`:

```toml
[tasks.dev]
description = "Start with custom settings"
command = "pnpm run dev --host 0.0.0.0"
```

This will override the `dev` task from any activated preset or global config.

## Configuration Priority Example

Given:
- Global config defines: `ls`, `status`
- Docker preset (activated) defines: `build`, `up`, `down`
- Local config defines: `build`, `custom`

Available tasks:
- `ls` (from global)
- `status` (from global)
- `build` (from local, overrides preset)
- `up` (from preset)
- `down` (from preset)
- `custom` (from local)

## Future Enhancements

The preset system can be extended with additional conditions:
- `when_dir`: Activate when a specific directory exists
- `when_env`: Activate based on environment variables
- `when_git_branch`: Activate based on current git branch
- Multiple conditions with AND/OR logic

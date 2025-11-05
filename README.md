# Vai
This a simple cli to manage and run project specific aliases.

## Usage
If a `.env` is found in the project all the defined variables are availble.

## Config
You can add commands like this:
```toml
[tasks.up]
description = "Start the application"
command = 'docker compose -p ${PROJECT:-$(pwd)} up -d'
```

## License
The MIT License (MIT). Please see [License File](LICENSE.md) for more information.

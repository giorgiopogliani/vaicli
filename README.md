# vai 

This a simple cli to manage and run project specific aliases. 

## Install

Make sure you have PHP 8.3 installed on your system and then run: 
```bash
curl -o /usr/local/bin/vai -fsSL https://github.com/giorgiopogliani/vaicli/releases/latest/download/application && chmod +x /usr/local/bin/vai
```

## Usage

Create a file called `vai.yml` and add your project specific alias. If a `.env` is found in the project all the defined variables are availble.

```yml
init:
  description: "Init project"
  command: vai shell composer install

shell:
  description: "Exec command inside the container"
  command: docker exec -it ${container} 

bash:
  description: "Run bash inside the container"
  command: docker exec -it ${container} bash
```

To run a command just pass the name as argument to the vai cli, for example: 
```shell
vai shell bash # this will run docker exec -it my-app-container bash
vai bash # this will also run docker exec -it my-app-container bash
```

Any extra argument/option will be forwarded to the actual command. 

## Presets

I have included a few presets that load automatically based on the project files. 
- Docker preset: general docker aliases (up, down, exec, etc...)
- Php preset: composer exec alias
- Laravel: artisan exec alias
- Craft Cms: craft exec alias and restore db alias

> [!NOTE]  
> These presets will assume you have a `PROJECT` and a `CONTAINER` env variable. 

## License

The MIT License (MIT). Please see [License File](LICENSE.md) for more information.

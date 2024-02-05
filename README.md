# vai 

This a simple cli to manage and run project specific aliases. 

## Install

Make sure you have  PHP 8.3 installed on your system and then run: 
```bash
curl https://github.com/giorgiopogliani/vaicli/releases/download/0.0.7/application -o /usr/local/bin/vai && chmod +x /usr/local/bin/vai
```

## Usage

Create a file called `vai.yml` and add your project specific alias

```yml
version: 1.0

variables:
  - name: container
    value: my-app-container

commands:
  - name: init
    description: "Init project"
    command: vai shell composer install

  - name: shell
    description: "Run shell inside the container"
    command: docker exec -it $(container) 

  - name: bash
    description: "Run bash inside the container"
    command: docker exec -it $(container) bash
```

To run a command just pass the name as argument to the vai cli, for example: 
```
vai init bash # this will run docker exec -it my-app-container bash
```

Any extra argument/option will be forwarded to the actual command. 


## License

The MIT License (MIT). Please see [License File](LICENSE.md) for more information.

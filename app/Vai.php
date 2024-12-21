<?php

declare(strict_types=1);

namespace App;

use App\VaiCommand;
use Dotenv\Dotenv;
use LaravelZero\Framework\Kernel;
use Symfony\Component\Yaml\Yaml;

use function Termwind\render;

class Vai
{
    /** @var VaiCommand[] */
    protected array $commands = [];

    protected array $presets = [];

    protected string $config;

    protected array $env;

    public function __construct(string $config = 'vai.yml')
    {
        $this->config = getcwd() . '/' . $config;
        $this->env = Dotenv::createUnsafeMutable(getcwd())->safeLoad();
    }

    public function getCommands(): array
    {
        return $this->commands;
    }

    public function loadConfig()
    {
        if (file_exists($this->config)) {
            $commands = Yaml::parse(file_get_contents($this->config));
            foreach ($commands as $key => $value) {
                $this->commands[] = new VaiCommand(
                    name: $key,
                    description: $value['description'],
                    command: $value['command']
                );
            }
        }
    }

    public function loadPresets()
    {
        foreach ($this->presets as $preset) {
            $this->commands = array_merge(
                $this->commands,
                $preset->getCommands()
            );
        }
    }

    public function load(Kernel $app): void
    {
        $this->loadConfig();

        $this->loadPresets();

        foreach ($this->commands as $entry) {
            $self = $this;
            $app->command($entry->name . ' {extra?*}', fn () => $self->runVaiCommand($entry, $this->argument('extra')));
        }
    }

    public function getCommand(VaiCommand $entry, $arguments = []): string
    {
        $command = explode(' ', $entry->command);

        foreach ($this->env as $name => $value) {
            $command = array_map(
                fn ($item) => str_replace('${' . $name . '}', $value, $item),
                $command
            );
        }

        return implode(' ', $command) . ' ' . implode(' ', $arguments);
    }

    public function runVaiCommand(VaiCommand $entry, array $arguments): void
    {
        $command = explode(' ', $entry->command);

        foreach ($this->env as $name => $value) {
            $command = array_map(
                fn ($item) => str_replace('${' . $name . '}', $value, $item),
                $command
            );
        }

        $string = implode(' ', $command) . ' ' . implode(' ', $arguments);
        render(<<<HTML
        <p>
            <i>Running '{$entry->name}' command: $string </i>
        </p>
        HTML);
        system($string . ' > `tty`');
    }

    public function addPreset(string $class): void
    {
        if ($class::shouldLoad()) {
            $this->presets[] = new $class();
        }
    }
}

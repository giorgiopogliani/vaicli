<?php

namespace App\Commands;

use Illuminate\Support\Facades\Process;
use LaravelZero\Framework\Commands\Command;
use Symfony\Component\Yaml\Yaml;

use function Laravel\Prompts\error;
use function Laravel\Prompts\warning;
use function Termwind\render;

class RunCommand extends Command
{
    protected $signature = 'run {name?} {arguments?*}';

    protected $description = 'Run a command from the vai.yml file.';

    public function handle(): void
    {
        $name = $this->argument('name');
        $arguments = $this->argument('arguments');

        $file = $this->getFile();
        if (! $name) {
            warning('Please provide a command name');
            $this->printSummary($file);
            exit(1);
        }

        $command = $this->getCommand($name, $file);
        if (! $command) {
            warning("Unknown command: $name");
            exit(1);
        }

        $variables = collect($file->variables)->mapWithKeys(function ($var) {
            return [$var->name => $var->value];
        });

        $fullCommand = [
            ...explode(' ', $command->command),
            ...$arguments
        ];

        for ($i = 0; $i < count($fullCommand); $i++) {
            $fullCommand[$i] = preg_replace_callback('/\$\(([^)]+)\)/', function ($matches) use ($variables) {
                return $variables[$matches[1]] ?? $matches[0];
            }, $fullCommand[$i]);
        }

        render("<p><span>Running '{$command->name}' command:</span> <span class='italic'>{$command->command} \$args</span></p>");

        Process::forever()->tty()->run($fullCommand);
    }

    public function getFile(): object
    {
        $path = getcwd() . DIRECTORY_SEPARATOR . 'vai.yml';

        if (! file_exists($path)) {
            error('No vai.yml file found');
            exit(1);
        }

        return Yaml::parseFile($path, Yaml::PARSE_OBJECT_FOR_MAP);
    }

    public function printSummary(object $file)
    {
        $output = '<ul>';
        foreach ($file->commands as $command) {
            $output .= "<li>
                <strong>{$command->name}</strong>: {$command->description}
            </li>";
        }
        $output .= '</ul>';
        render($output);
    }

    public function getCommand(string $name, object $file): ?object
    {
        foreach ($file->commands as $command) {
            if ($command->name === $name) {
                return $command;
            }
        }

        return null;
    }
}

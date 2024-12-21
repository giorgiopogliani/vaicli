<?php

namespace App\Commands;

use LaravelZero\Framework\Commands\Command;

use function Termwind\render;

class HelpCommand extends Command
{
    private $command;

    protected $signature = 'help';

    protected $description = 'Command description';

    public function handle()
    {
        global $vai;

        $project = env('PROJECT');
        $container = env('CONTAINER');

        if ($this->command) {
            $entry = collect($vai->getCommands())
                ->filter(fn ($entry) => $entry->name === $this->command->getName())
                ->first();

            $command = $vai->getCommand($entry);

            render(<<<HTML
            <p>
                <strong>{$entry->name}</strong><br><br>
                <span>{$entry->description}</span><br><br>
                <i>{$entry->command}</i><br>
                <i>{$command}</i>
            </p>
            HTML);
        } else {
            render(<<<HTML
            <p>
                <strong>Usage: vai [command] [arguments] </strong><br><br>
                <i>PROJECT</i>: <span>{$project}</span><br>
                <i>CONTAINER</i>: <span>{$container}</span>
            </p>
            HTML);

            foreach ($vai->getCommands() as $entry) {
                render(<<<HTML
                <span>
                    <strong>{$entry->name}</strong>: <i>{$entry->description}</i>
                </span>
                HTML);
            }
        }

        return 0;
    }

    public function setCommand($command): void
    {
        $this->command = $command;
    }
}

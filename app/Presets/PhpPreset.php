<?php

declare(strict_types=1);

namespace App\Presets;

use App\VaiCommand;

class PhpPreset
{
    public static function shouldLoad(): bool
    {
        return DockerPreset::shouldLoad() && file_exists(getcwd() . '/composer.json');
    }

    public function getCommands(): array
    {
        return [
            new VaiCommand(
                name: 'composer',
                description: 'Run composer inside the container',
                command: 'vai exec composer'
            )
        ];
    }
}

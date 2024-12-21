<?php

declare(strict_types=1);

namespace App\Presets;

use App\VaiCommand;

class LaravelPreset
{
    public static function shouldLoad(): bool
    {
        return file_exists(getcwd() . '/artisan');
    }

    public function getCommands(): array
    {
        return [
           new VaiCommand(
               name: 'artisan',
               description: 'Run artisan inside the container',
               command: 'vai exec php artisan'
           ),
        ];
    }
}

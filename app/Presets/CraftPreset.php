<?php

declare(strict_types=1);

namespace App\Presets;

use App\VaiCommand;

class CraftPreset
{
    public static function shouldLoad(): bool
    {
        return file_exists(getcwd() . '/craft');
    }

    public function getCommands(): array
    {
        return [
           new VaiCommand(
               name: 'craft',
               description: 'Run craft inside the container',
               command: 'vai exec php craft'
           ),
           new VaiCommand(
               name: 'restore',
               description: 'Restore the database from config/db/seed.sql.zip',
               command: 'vai exec php craft db/restore config/db/seed.sql.zip'
           )
        ];
    }
}

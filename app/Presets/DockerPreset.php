<?php

declare(strict_types=1);

namespace App\Presets;

use App\VaiCommand;

class DockerPreset
{
    public static function shouldLoad(): bool
    {
        return file_exists(getcwd() . '/docker-compose.yml');
    }

    public function getCommands(): array
    {
        return [
            new VaiCommand(
                name: 'compose',
                description: 'Run docker compose for the project',
                command: 'docker compose -p ${PROJECT}'
            ),
           new VaiCommand(
               name: 'up',
               description: 'Build and start the container',
               command: 'docker compose -p ${PROJECT} up -d --build --remove-orphans'
           ),
           new VaiCommand(
               name: 'down',
               description: 'Stop and remove the container',
               command: 'docker compose -p ${PROJECT} down'
           ),
           new VaiCommand(
               name: 'start',
               description: 'Start the container',
               command: 'docker compose -p ${PROJECT} start'
           ),
           new VaiCommand(
               name: 'stop',
               description: 'Stop the container',
               command: 'docker compose -p ${PROJECT} stop'
           ),
           new VaiCommand(
               name: 'logs',
               description: 'View logs from the project',
               command: 'docker compose -p ${PROJECT} logs -f -t'
           ),
           new VaiCommand(
               name: 'exec',
               description: 'Run given command inside the container',
               command: 'docker exec -it ${CONTAINER}'
           ),
           new VaiCommand(
               name: 'bash',
               description: 'Run bash inside the container',
               command: 'docker exec -it ${CONTAINER} bash'
           ),
        ];
    }
}

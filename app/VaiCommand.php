<?php

declare(strict_types=1);

namespace App;

class VaiCommand
{
    public function __construct(
        readonly public string $name,
        readonly public string $description,
        readonly public string $command
    ) {}
}

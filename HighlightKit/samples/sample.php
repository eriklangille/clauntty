<?php

declare(strict_types=1);

namespace Review;

/** A file in a review */
final class ReviewFile
{
    public function __construct(
        private string $path,
        private int $added = 0,
    ) {}

    public function label(): string
    {
        return sprintf("%s (+%d)", $this->path, $this->added) . "\n";
    }
}

$file = new ReviewFile("src/app.php", added: 12);
echo $file->label();

<?php

namespace App\Security\Controller;

use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\Routing\Annotation\Route;

class ApiKeyController extends AbstractController
{
    public function __construct(private readonly EntityManagerInterface $entityManager)
    {
    }

    #[Route('/api/key/generate', name: 'api_key_generate', methods: ['POST'])]
    public function generate(): JsonResponse
    {
        $chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
        $key = '';
        for ($i = 0; $i < 32; $i++) {
            $key .= $chars[random_int(0, strlen($chars) - 1)];
        }

        $user = $this->getUser();
        if ($user !== null) {
            $user->setApiKey($key);
            $this->entityManager->flush();
        }

        return new JsonResponse(['api_key' => $key]);
    }
}

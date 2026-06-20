<?php
/**
 * SuiteCRM is a customer relationship management program developed by SuiteCRM Ltd.
 * Copyright (C) 2021 SuiteCRM Ltd.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License version 3 as published by the
 * Free Software Foundation with the addition of the following permission added
 * to Section 15 as permitted in Section 7(a): FOR ANY PART OF THE COVERED WORK
 * IN WHICH THE COPYRIGHT IS OWNED BY SUITECRM, SUITECRM DISCLAIMS THE
 * WARRANTY OF NON INFRINGEMENT OF THIRD PARTY RIGHTS.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * In accordance with Section 7(b) of the GNU Affero General Public License
 * version 3, these Appropriate Legal Notices must retain the display of the
 * "Supercharged by SuiteCRM" logo. If the display of the logos is not reasonably
 * feasible for technical reasons, the Appropriate Legal Notices must display
 * the words "Supercharged by SuiteCRM".
 */


namespace App\Authentication\Controller;

use App\Authentication\LegacyHandler\UserHandler;
use App\Data\LegacyHandler\PreparedStatementHandler;
use App\Engine\LegacyHandler\CacheManagerHandler;
use Doctrine\DBAL\Exception;
use Doctrine\ORM\EntityManagerInterface;
use Endroid\QrCode\Builder\Builder;
use Endroid\QrCode\Encoding\Encoding;
use App\Authentication\LegacyHandler\Authentication;
use App\Module\Users\Entity\User;
use Endroid\QrCode\ErrorCorrectionLevel;
use Endroid\QrCode\RoundBlockSizeMode;
use Endroid\QrCode\Writer\SvgWriter;
use RuntimeException;
use Scheb\TwoFactorBundle\Security\TwoFactor\Provider\Totp\TotpAuthenticatorInterface;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Bundle\SecurityBundle\Security;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\RequestStack;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Annotation\Route;
use Symfony\Component\Security\Core\User\UserInterface;
use Symfony\Component\Security\Http\Attribute\CurrentUser;
use Symfony\Component\Security\Http\Attribute\IsGranted;
use Symfony\Component\Security\Http\Authentication\AuthenticationUtils;

/**
 * Class SecurityController
 * @package App\Controller
 */
class SecurityController extends AbstractController
{
    /**
     * @var Authentication
     */
    private $authentication;

    /**
     * @var RequestStack
     */
    private $requestStack;

    /**
     * @var EntityManagerInterface
     */
    private $entityManager;
    private PreparedStatementHandler $preparedStatementHandler;


    private UserHandler $userHandler;

    private CacheManagerHandler $cacheManagerHandler;
    /**
     * SecurityController constructor.
     * @param Authentication $authentication
     * @param RequestStack $requestStack
     */
    public function __construct(
        Authentication           $authentication,
        RequestStack             $requestStack,
        EntityManagerInterface   $entityManager,
        PreparedStatementHandler $preparedStatementHandler,
        UserHandler $userHandler,
        CacheManagerHandler $cacheManagerHandler
    )
    {
        $this->authentication = $authentication;
        $this->requestStack = $requestStack;
        $this->entityManager = $entityManager;
        $this->preparedStatementHandler = $preparedStatementHandler;
        $this->userHandler = $userHandler;
        $this->cacheManagerHandler = $cacheManagerHandler;
    }

    /**
     * @param AuthenticationUtils $authenticationUtils
     * @param User|null $user
     * @return JsonResponse
     */
    #[Route('/login', name: 'app_login', methods: ["GET", "POST"])]
    public function login(AuthenticationUtils $authenticationUtils, #[CurrentUser] ?User $user): JsonResponse
    {
        $error = $authenticationUtils->getLastAuthenticationError();
        $isAppInstalled = $this->authentication->getAppInstallStatus();
        $isAppInstallerLocked = $this->authentication->getAppInstallerLockStatus();
        $appStatus = [
            'installed' => $isAppInstalled,
            'locked' => $isAppInstallerLocked,
            'loginWizardCompleted' => true
        ];

        if ($error) {
            return $this->json([
                'active' => false,
                'message' => 'missing credentials'
            ], Response::HTTP_UNAUTHORIZED);
        }

        if (null === $user) {
            return $this->json([
                'active' => false,
                'message' => 'missing credentials',
            ], Response::HTTP_UNAUTHORIZED);
        }

        $data = $this->getResponseData($user, $appStatus);

        $data['login_success'] = true;

        $needsRedirect = $this->authentication->needsRedirect($user);
        if (!empty($needsRedirect)) {
            $data['redirect'] = $needsRedirect;
        }

        $data['user'] = $user->getUserIdentifier();
        return $this->json($data, Response::HTTP_OK);
    }


    /**
     * @throws Exception
     */
    #[Route('/2fa/enable', name: 'app_2fa_enable', methods: ["GET", "POST"])]
    #[IsGranted('IS_AUTHENTICATED_FULLY')]
    public function enable2fa(#[CurrentUser] ?User $user, TotpAuthenticatorInterface $totpAuthenticator): Response
    {
        $secret = $totpAuthenticator->generateSecret();

        $user->setTotpSecret($secret);

        $qrCodeUrl = $totpAuthenticator->getQRContent($user);

        $this->preparedStatementHandler->update(
            'UPDATE users SET totp_secret = :totp_secret WHERE id = :id',
            ['totp_secret' => $secret, 'id' => $user->getId()],
            [['param' => 'totp_secret', 'type' => 'string'], ['param' => 'id', 'type' => 'string']]
        );

        $this->entityManager->flush();

        $response = [
            'url' => $qrCodeUrl,
            'svg' => $this->displayQRCode($qrCodeUrl),
            'secret' => $secret,
        ];
        return new Response(json_encode($response), Response::HTTP_OK);
    }

    #[Route('/2fa/disable', name: 'app_2fa_disable', methods: ["GET"])]
    public function disable2fa(#[CurrentUser] ?User $user, TotpAuthenticatorInterface $totpAuthenticator): Response
    {
        $user->setTotpSecret(null);

        $this->preparedStatementHandler->update(
            'UPDATE users SET totp_secret = NULL WHERE id = :id',
            ['id' => $user->getId()],
            [['param' => 'id', 'type' => 'string']]
        );

        $this->entityManager->flush();

        $this->cacheManagerHandler->markAsNeedsUpdate('app-metadata-user-preferences-' . $user->getId());

        return new Response(json_encode(['two_factor_disabled' => true]), Response::HTTP_OK);
    }

    #[Route('/2fa/enable-finalize', name: 'app_2fa_enable_finalize', methods: ["GET", "POST"])]
    #[IsGranted('IS_AUTHENTICATED_FULLY')]
    public function enable2faFinalize(
        Request $request,
        #[CurrentUser] ?User $user,
        TotpAuthenticatorInterface $totpAuthenticator
    ): Response
    {
        $auth_code = $request->getPayload()->get('auth_code') ?? '';

        $correctCode = $totpAuthenticator->checkCode($user, $auth_code);

        if ($correctCode) {
            $this->userHandler->setUserPreference('is_two_factor_enabled', true);
            $this->preparedStatementHandler->update(
                'UPDATE users SET is_totp_enabled = true WHERE id = :id',
                ['id' => $user->getId()],
                [['param' => 'id', 'type' => 'string']]
            );
        }

        $this->cacheManagerHandler->markAsNeedsUpdate('app-metadata-user-preferences-' . $user->getId());

        $response = ['two_factor_setup_complete' => $correctCode];
        return new Response(json_encode($response), Response::HTTP_OK);
    }

    #[Route('/logout', name: 'app_logout', methods: ["GET", "POST"])]
    public function logout(): void
    {
        // throw will be intercepted by logout key
        throw new RuntimeException('This will be intercepted by the logout key');
    }

    #[Route('/session-status', name: 'app_session_status', methods: ["GET"])]
    public function sessionStatus(Security $security): JsonResponse
    {
        try {
            $isAppInstalled = $this->authentication->getAppInstallStatus();
        } catch (\Throwable $e) {
            $isAppInstalled = false;
        }
        try {
            $isAppInstallerLocked = $this->authentication->getAppInstallerLockStatus();
        } catch (\Throwable $e) {
            $isAppInstallerLocked = false;
        }
        $appStatus = [
            'installed' => $isAppInstalled,
            'locked' => $isAppInstallerLocked,
            'loginWizardCompleted' => true
        ];
        if (!$isAppInstalled) {
            $response = new JsonResponse(['appStatus' => $appStatus], Response::HTTP_OK);
            $response->headers->clearCookie('XSRF-TOKEN');
            $this->requestStack->getSession()->invalidate();
            $this->requestStack->getSession()->start();
            return $response;
        }
        try {
            $isActive = $this->authentication->checkSession();
        } catch (\Throwable $e) {
            $isActive = false;
        }
        if ($isActive !== true) {
            $response = new JsonResponse(['active' => false, 'appStatus' => $appStatus], Response::HTTP_OK);
            $this->requestStack->getSession()->invalidate();
            $this->requestStack->getSession()->start();
            $this->authentication->initLegacySystemSession();
            return $response;
        }
        try {
            $user = $security->getUser();
        } catch (\Throwable $e) {
            $user = null;
        }
        if ($user === null) {
            $response = new JsonResponse(['active' => false, 'appStatus' => $appStatus], Response::HTTP_OK);
            return $response;
        }
        try {
            $isUserActive = $this->authentication->isUserActive();
        } catch (\Throwable $e) {
            $isUserActive = false;
        }
        if ($isUserActive !== true) {
            $response = new JsonResponse(['active' => false, 'appStatus' => $appStatus], Response::HTTP_OK);
            return $response;
        }
        try {
            $isLoginWizardCompleteStatus = $this->authentication->getLoginWizardCompletedStatus();
        } catch (\Throwable $e) {
            $isLoginWizardCompleteStatus = false;
        }
        if ($isLoginWizardCompleteStatus) {
            $appStatus['loginWizardCompleted'] = true;
        } else {
            $appStatus['loginWizardCompleted'] = false;
        }
        try {
            $data = $this->getResponseData($user, $appStatus);
        } catch (\Throwable $e) {
            $response = new JsonResponse(['active' => false, 'appStatus' => $appStatus], Response::HTTP_INTERNAL_SERVER_ERROR);
            return $response;
        }
        if (!isset($data['redirect'])){
            try {
                $needsRedirect = $this->authentication->needsRedirect($user);
                if (!empty($needsRedirect)) {
                    $data['redirect'] = $needsRedirect;
                }
            } catch (\Throwable $e) {
            }
        }
        return new JsonResponse($data, Response::HTTP_OK);
    }

    #[Route('/auth/login', name: 'native_auth_login', methods: ["GET", "POST"])]
    public function nativeAuthLogin(AuthenticationUtils $authenticationUtils, #[CurrentUser] ?User $user): JsonResponse
    {
        $result = $this->login($authenticationUtils, $user);
        return $result;
    }

    #[Route('/auth/logout', name: 'native_auth_logout', methods: ["GET", "POST"])]
    public function nativeAuthLogout(): void
    {
        $this->logout();
    }

    #[Route('/auth/session-status', name: 'native_auth_session_status', methods: ["GET"])]
    public function nativeAuthSessionStatus(Security $security): JsonResponse
    {
        $result = $this->sessionStatus($security);
        return $result;
    }

    #[Route('/auth/2fa_check', name: 'native_auth_2fa_check', methods: ["GET", "POST"])]
    public function nativeCheckTwoFactorCode(Request $request): Response
    {
        $result = $this->redirectToRoute('app_2fa_check', $request->query->all());
        return $result;
    }

    /**
     * @param User $user
     * @param $appStatus
     * @return array
     */
    private function getResponseData(User $user, $appStatus): array
    {
        $result = [
            'appStatus' => $appStatus,
            'active' => true,
            'id' => $user->getId(),
            'firstName' => $user->getFirstName(),
            'lastName' => $user->getLastName(),
            'userName' => $user->getUserIdentifier()
        ];
        return $result;
    }

    private function displayQRCode(string $qrCodeUrl): string
    {
        $builder = new Builder(
            writer: new SvgWriter(),
            writerOptions: [],
            validateResult: false,
            data: $qrCodeUrl,
            encoding: new Encoding('UTF-8'),
            errorCorrectionLevel: ErrorCorrectionLevel::Medium,
            size: 200,
            margin: 0,
            roundBlockSizeMode: RoundBlockSizeMode::Margin,
        );
        $result = $builder->build();
        return $result->getString();
    }

}

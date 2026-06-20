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

namespace App\Authentication\LegacyHandler;

use App\Engine\LegacyHandler\LegacyHandler;
use App\Engine\LegacyHandler\LegacyScopeState;
use App\Install\Service\InstallationUtilsTrait;
use AuthenticationController;
use Symfony\Component\HttpFoundation\RequestStack;
use Symfony\Component\Security\Core\User\UserInterface;

/**
 * Class Authentication
 */
class Authentication extends LegacyHandler
{
    use InstallationUtilsTrait;

    public const HANDLER_KEY = 'authentication';
    protected $config;
    private $systemSettings;
    private $userHandler;

    public function __construct(
        string           $projectDir,
        string           $legacyDir,
        string           $legacySessionName,
        string           $defaultSessionName,
        LegacyScopeState $legacyScopeState,
        RequestStack     $session,
        array            $systemSettings,
        UserHandler      $userHandler
    ) {
        parent::__construct(
            $projectDir,
            $legacyDir,
            $legacySessionName,
            $defaultSessionName,
            $legacyScopeState,
            $session
        );
        $this->systemSettings = $systemSettings;
        $this->userHandler = $userHandler;
    }

    public function getHandlerKey(): string
    {
        $key = self::HANDLER_KEY;
        return $key;
    }

    public function setConfig($config): self
    {
        $this->config = $config;
        return $this;
    }

    public function needsRedirect(UserInterface $user): array
    {
        $this->init();

        /** @var \User $current_user */
        global $current_user;

        $timezone = $current_user->getPreference('timezone');
        $ut = $current_user->getPreference('ut');

        if (empty($ut) || empty($timezone)) {
            $this->close();
            $result = $this->systemSettings['setup_wizard_route'] ?? ['route' => 'users/wizard'];
            return $result;
        }

        /* @noinspection PhpIncludeInspection */
        require_once 'modules/Users/password_utils.php';

        if (hasPasswordExpired($user->getUsername())) {
            $this->close();
            $result = [
                'route' => 'users/ChangePassword',
                'queryParams' => ['record' => $current_user->id]
            ];
            return $result;
        }

        $this->close();
        return [];
    }

    public function getLoginWizardCompletedStatus(): bool
    {
        $this->init();
        $user = $this->userHandler->getCurrentUser();
        $ut = $user->getPreference('ut') ?? '';
        $this->close();
        $result = !empty($ut);
        return $result;
    }

    public function initLegacyUserSession($username): bool
    {
        $this->init();

        $language = $this->userHandler->getSessionLanguage();
        if (empty($language)) {
            $language = $this->userHandler->getSystemLanguage();
        }

        global $mod_strings;

        $authController = $this->getAuthenticationController();

        $result = $authController->initUserSession($username);

        $userPrefLanguage = $this->userHandler->getUserPreferencesLanguage();

        if (!empty($userPrefLanguage)){
            $language = $userPrefLanguage;
        }

        $mod_strings = return_module_language($language, 'Users');

        $this->close();

        $this->userHandler->setSessionLanguage($language);

        return $result;
    }

    protected function getAuthenticationController(): AuthenticationController
    {
        $controller = new AuthenticationController();
        return $controller;
    }

    public function logout(): void
    {
        $this->init();

        $authController = $this->getAuthenticationController();

        $authController->logout(false, false, false);

        $this->close();
    }

    public function initLegacySystemSession(): void
    {
        $this->init();
        $this->loadSystemUser();
        $this->close();
    }

    public function checkSession(): bool
    {
        $this->init();
        $authController = $this->getAuthenticationController();
        $result = $authController->checkSession();
        $this->close();
        return $result;
    }

    public function isUserActive(): bool
    {
        $this->init();
        $authController = $this->getAuthenticationController();
        $result = $authController->isUserActive();
        $this->close();
        return $result;
    }

    public function getAppInstallStatus(): bool
    {
        $this->init();
        $result = $this->isAppInstalled($this->legacyDir);
        $this->close();
        return $result;
    }

    public function getAppInstallerLockStatus(): bool
    {
        $this->init();
        $result = $this->isAppInstallerLocked($this->legacyDir);
        $this->close();
        return $result;
    }

    public function callLegacyHooks(string $module, string $key): void
    {
        $this->init();
        $this->startLegacyApp();

        \LogicHook::initialize()->call_custom_logic($module, $key);

        $this->close();
    }

    public function callLegacyUserHooks(string $key): void
    {
        $this->init();
        $this->startLegacyApp();

        if (isset($GLOBALS['current_user'])) {
            $GLOBALS['current_user']->call_custom_logic($key);
        }

        $this->close();
    }
}

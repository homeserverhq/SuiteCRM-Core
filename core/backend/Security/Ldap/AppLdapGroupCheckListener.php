<?php

namespace App\Security\Ldap;

use App\Module\Users\Entity\User;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\Ldap\Ldap;
use Symfony\Component\Security\Core\Exception\AccessDeniedException;
use Symfony\Component\Security\Http\Authenticator\Passport\Badge\UserBadge;
use Symfony\Component\Security\Http\Event\CheckPassportEvent;
use Symfony\Component\Ldap\Security\LdapBadge;

class AppLdapGroupCheckListener implements EventSubscriberInterface
{
    private ?Ldap $ldap = null;
    private string $groupName;
    private string $groupAttr;
    private string $groupObjectClass;
    private string $groupBaseDn;
    private ?string $searchDn;
    private ?string $searchPassword;
    private string $authType;
    private string $userBaseDn;

    public function __construct(
        ?Ldap $ldap = null,
        string $groupName = 'primaryusers',
        string $groupAttr = 'uniqueMember',
        string $groupObjectClass = 'groupOfUniqueNames',
        string $groupBaseDn = '',
        ?string $searchDn = null,
        ?string $searchPassword = null,
        string $authType = 'native',
        string $userBaseDn = ''
    ) {
        $this->ldap = $ldap;
        $this->groupName = $groupName;
        $this->groupAttr = $groupAttr;
        $this->groupObjectClass = $groupObjectClass;
        $this->groupBaseDn = $groupBaseDn;
        $this->searchDn = $searchDn;
        $this->searchPassword = $searchPassword;
        $this->authType = $authType;
        $this->userBaseDn = $userBaseDn;
    }

    public static function getSubscribedEvents(): array
    {
        return [CheckPassportEvent::class => ['checkPassport', 0]];
    }

    public function checkPassport(CheckPassportEvent $event): void
    {
        $passport = $event->getPassport();

        if ($this->authType !== 'ldap') {
            return;
        }

        if ($this->ldap === null) {
            return;
        }

        if (!$passport->hasBadge(LdapBadge::class)) {
            return;
        }

        $ldapBadge = $passport->getBadge(LdapBadge::class);
        if (!$ldapBadge->isResolved()) {
            return;
        }

        $userBadge = $passport->getBadge(UserBadge::class);
        $username = $userBadge->getUserIdentifier();
        $user = $userBadge->getUser();
        if ($user instanceof User && empty($user->getExternalAuthOnly())) {
            return;
        }

        if ($this->searchDn && $this->searchPassword) {
            $this->ldap->bind($this->searchDn, $this->searchPassword);
        }

        $userQuery = $this->ldap->query(
            $this->userBaseDn,
            sprintf('(&(objectClass=inetOrgPerson)(uid=%s))', $this->ldap->escape($username))
        );
        $userResult = $userQuery->execute();
        if (count($userResult) === 0) {
            throw new AccessDeniedException('User not found in LDAP directory');
        }

        $userEntry = $userResult[0];
        $userDn = $userEntry->getDn();

        $groupQuery = $this->ldap->query(
            $this->groupBaseDn,
            sprintf(
                '(&(objectClass=%s)(cn=%s))',
                $this->ldap->escape($this->groupObjectClass),
                $this->ldap->escape($this->groupName)
            )
        );
        $groupResult = $groupQuery->execute();

        if (count($groupResult) === 0) {
            throw new AccessDeniedException('Group not found: ' . $this->groupName);
        }

        $groupEntry = $groupResult[0];
        $members = $groupEntry->getAttribute($this->groupAttr);
        if ($members === null || !in_array($userDn, $members, true)) {
            throw new AccessDeniedException(
                'User is not a member of the required group: ' . $this->groupName
            );
        }
    }
}

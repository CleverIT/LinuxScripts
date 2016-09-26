#!/usr/bin/php
<?php

error_reporting(E_ALL | E_STRICT);
ini_set('display_errors', 'On');

require_once('config.inc.php');

/* GENEREREN */
echo 'Genereren van virtual host file...' . "\n";

// Bepaal over te slaan websites
$skipFolders = [];
if (file_exists('skip-folders.txt')) {
    $skipFolders = trim(str_replace("\r", '', file_get_contents('skip-folders.txt')));
    $skipFolders = array_filter(explode("\n", $skipFolders));
}

$contents = '';
$FPMContents = '';
$createDirs = [];
foreach ($vhosts as $name => $groupConfig) {
    if(isset($groupConfig['allow'])) {
        if ($groupConfig['allow'] == 'whitelist') {
            $allow = false;
        } else {
            $allow = $groupConfig['allow'];
        }
    } else {
        $allow = 'all';
    }
    $defaultIP = isset($groupConfig['defaultIP']) ? $groupConfig['defaultIP'] : '*';

    $currentVhostPath = sprintf($vhostsPath, $name);

    $contents .= 'FastCGIExternalServer /home/' . $name . '/vhosts/php5.fcgi -socket /var/run/php5-fpm-' . $name . '.sock -pass-header Authorization -idle-timeout 3600 -flush' . "\n";

    $contents .= '<Directory ' . $currentVhostPath . '>' . "\n";
    $contents .= "\t" . 'Order Allow,Deny' . "\n";
    $contents .= "\t" . 'Options +Indexes' . "\n";
    $contents .= "\t" . 'AllowOverride all' . "\n";
    if ($allow !== false) {
        $contents .= "\t" . 'Allow from ' . $allow . "\n";
        $contents .= "\t" . 'Require ' . $allow . ' granted' . "\n";
    } else {
        echo 'Whitelist used' . PHP_EOL;
        $contents .= "\t" . 'Allow from all' . "\n";
        $whitelistRaw = file('whitelist.txt');
        foreach($whitelistRaw as $whiteListEntry) {
            if (substr($whiteListEntry, 0, 1) == '#') continue;
            if (trim($whiteListEntry) == '') continue;
            if (substr($whiteListEntry, 0, 5) == 'host ') {
                $contents .= "\t" . 'Require ip ' . gethostbyname(trim(substr($whiteListEntry, 5, strlen($whiteListEntry)))) . "\n";
            } else {
                $contents .= "\t" . 'Require ip ' . trim($whiteListEntry) . "\n";
            }
        }
    }
    $contents .= '</Directory>' . "\n";

    foreach ($groupConfig['vhosts'] as $serverName => $serverConfig) {
            $currentWebsitePath = sprintf($websitePath, $name, $serverConfig['target']);
            foreach ($skipFolders as $skipFolder) {
                if (substr($currentWebsitePath, 0, strlen($skipFolder)) == $skipFolder) {
                    continue 2;
                }
            }

            if (!is_dir($currentWebsitePath) && !file_exists($currentWebsitePath)) {
                $createDirs[] = ['path' => $currentWebsitePath, 'user' => $name];
            }

            $IP = isset($serverConfig['IP']) ? $serverConfig['IP'] : $defaultIP;
            $ports = isset($serverConfig['port']) ? [$serverConfig['port']] : $serverConfig['ports'];
            $aliases = isset($serverConfig['aliases']) ? $serverConfig['aliases'] : [];
            $sslCert = isset($serverConfig['sslCert']) ? $serverConfig['sslCert'] : $genericSSLCert;
            $sslKey = isset($serverConfig['sslKey']) ? $serverConfig['sslKey'] : $genericSSLKey;
            $customConfig = isset($serverConfig['customConfig']) ? $serverConfig['customConfig'] : [];
            foreach ($ports as $port) {
                    $contents .= '<VirtualHost ' . $IP . ':' . $port . '>' . "\n";
                    $contents .= "\t" . 'ServerName ' . $serverName . "\n";
                    if (count($aliases) > 0) {
                        $contents .= "\t" . 'ServerAlias ' . implode(' ', $aliases) . "\n";
                    }
                    $contents .= "\t" . 'DocumentRoot ' . $currentWebsitePath . "\n";
                    $contents .= "\t" . 'Alias /php5.fcgi /home/' . $name . '/vhosts/php5.fcgi' . "\n";
                    if ($port == 443) {
                        $contents .= "\t" . 'SSLEngine on' . "\n";
                        $contents .= "\t" . 'SSLCertificateFile ' . $sslCert . "\n";
                        $contents .= "\t" . 'SSLCertificateKeyFile ' . $sslKey . "\n";
                    }
                    if (isset($serverConfig['allow'])) {
                        $contents .= "\t" . '<Directory ' . $currentWebsitePath . '>' . "\n";
                        $contents .= "\t\t" . 'Order Allow,Deny' . "\n";
                        $contents .= "\t\t" . 'Allow from ' . $serverConfig['allow'] . "\n";
                        $contents .= "\t" . '</Directory>' . "\n";
                    }
                    foreach ($customConfig as $customLine) {
                        $contents .= "\t" . trim($customLine) . "\n";
                    }
                    $contents .= '</VirtualHost>' . "\n";
            }
    }

    // Add FPM
    $FPMContents .= '[' . $name . ']' . "\n";
    $FPMContents .= 'user = ' . $name . "\n";
    $FPMContents .= 'group = ' . $name . "\n";

    $FPMContents .= 'listen = /var/run/php5-fpm-' . $name . '.sock' . "\n";
    $FPMContents .= "listen.owner = www-data\n";
    $FPMContents .= 'listen.group = ' . $name . "\n";

    $FPMContents .= 'pm = ondemand' . "\n";
    $FPMContents .= 'pm.max_children = ' . $FPMMaxChildren . "\n";
    $FPMContents .= 'pm.process_idle_timeout = 60s' . "\n";
    $FPMContents .= 'pm.max_requests = 3000' . "\n";

    $FPMContents .= 'php_admin_value[error_log] = ' . $currentVhostPath . '/phperrors.log' . "\n";
    $FPMContents .= 'php_admin_value[session.save_path] = ' . $currentVhostPath . '/sessions/' . "\n";
    $FPMContents .= 'php_admin_value[upload_tmp_dir] = ' . $currentVhostPath . '/uploadtmp/' . "\n";

    $FPMContents .= "\n";
}

// Schrijf config weg
file_put_contents($vhostFile, $contents);

// Write FPM pools
file_put_contents($FPMPoolsFile, $FPMContents);

// Create new folders
foreach ($createDirs as $createDirInfo) {
    $path = $createDirInfo['path'];
    $user = $createDirInfo['user'];
    mkdir($path, 0750, true);
    system('chown ' . $user . ':' . $user . ' ' . $path);
}

/* INSTALLEREN */
echo 'Installeren van nieuwe configuratie...' . "\n";

$backupVhost = $vhostFile . '.backup';
$targetVhost = $apacheVhostDir . $vhostFile;
if (file_exists($backupVhost)) {
        throw new Exception('Backup vhost file is in place, will not overwrite');
} else if (!file_exists($targetVhost)) {
        throw new Exception('Vhost file is missing');
}

copy($targetVhost, $backupVhost);
copy($vhostFile, $targetVhost);

/* TESTEN */
echo 'Testen van nieuwe configuratie...' . "\n";
$status = 0;
system('sudo apache2ctl -t', $status);
if ($status) {
        throw new Exception('Check on new configuration file failed with exit status ' . $status);
}

/* APACHE2 RESTART */
echo 'Reloaden van Apache2...' . "\n";
$status = 0;
system('sudo service apache2 reload', $status);
if ($status) {
        throw new Exception('Failed to reload Apache2');
}

// FPM restart
echo 'Restarting PHP5 FPM pools...' . "\n";
system('sudo service php5-fpm restart', $status);
if ($status) {
    throw new Exception('Failed to restart PHP5-FPM.');
}

/* REMOVE FILES */
echo 'Bestanden opschonen...' . "\n";
unlink($vhostFile);
unlink($backupVhost);

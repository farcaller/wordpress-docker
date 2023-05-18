{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }: flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      tini = pkgs.tini;
      php = pkgs.php;
      caddy = pkgs.caddy;

      wordpress = let src = pkgs.wordpress; in
        pkgs.stdenv.mkDerivation rec {
          pname = "wordpress";
          version = src.version;
          inherit src;

          installPhase = ''
            mkdir -p $out
            cp -r * $out/

            # symlink the wordpress config
            ln -sf /config/wp-config.php $out/share/wordpress/wp-config.php

            rm -rf $out/share/wordpress/wp-content
            ln -sf /data $out/share/wordpress/wp-content
          '';
        };

      wordpressRootDir = "${wordpress}/share/wordpress";

      phpFpmConfig = pkgs.writeText "php-fpm.conf" ''
        [global]
        error_log = /proc/self/fd/2

        [wordpress]
        access.log = /proc/self/fd/2
        listen = 0.0.0.0:8001
        pm = static
        pm.max_children = 1
      '';

      caddyConfig = pkgs.writeText "Caddyfile" ''
        {
          auto_https off
        }

        :80 {
          root * ${wordpressRootDir}
          encode zstd gzip

          log {
            output stderr
            format json
          }

          php_fastcgi http://{$PHP_ADDRESS}:{$PHP_PORT}
          file_server

          @disallowed {
            path /xmlrpc.php
            path *.sql
            path /wp-content/uploads/*.php
          }

          rewrite @disallowed '/index.php'
        }
      '';

      runner = pkgs.resholve.writeScriptBin "runner"
        {
          inputs = [ php caddy pkgs.busybox ];
          interpreter = "${pkgs.dash}/bin/dash";
          execer = [
            "cannot:${php}/bin/php-fpm"
            "cannot:${caddy}/bin/caddy"
          ];
        } ''
        run_php() {
          exec php-fpm -F -y ${phpFpmConfig} -c ${php}/etc/php.ini
        }

        run_caddy() {
          exec caddy run --config ${caddyConfig} --adapter caddyfile
        }

        run_test() {
          php-fpm -F -y ${phpFpmConfig} -c ${php}/etc/php.ini &
          caddy run --config ${caddyConfig} --adapter caddyfile
        }

        case "$1" in
          php)
            echo "running php-fpm"
            run_php
            ;;
          caddy)
            echo "running caddy"
            run_caddy
            ;;
          test)
            echo "running both for testing"
            run_test
            ;;
          *)
            exit 2
            ;;
        esac
      '';
    in
    {
      caddyConfig = caddyConfig;
      dockerImage = pkgs.dockerTools.buildImage {
        name = "ghcr.io/farcaller/wordpress-docker";
        tag = "latest";
        config = {
          Entrypoint = [ "${tini}/bin/tini" "--" "${runner}/bin/runner" ];
          Labels."org.opencontainers.image.source" = "https://github.com/farcaller/wordpress-docker";
          WorkingDir = wordpressRootDir;
        };
      };
      version = wordpress.version;
    }
  );
}

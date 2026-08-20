/** The only official Codex extension version currently proven compatible with the follower IPC. */
export const SUPPORTED_CODEX_EXTENSION_VERSIONS = ['26.814.41407'] as const;
export const TESTED_CODEX_EXTENSION_VERSION = SUPPORTED_CODEX_EXTENSION_VERSIONS[0];

export interface CodexExtensionCompatibility {
    supported: boolean;
    version?: string;
    detail: string;
}

/** Checks one exact installed extension version; ranges and unknown values fail closed. */
export function checkCodexExtensionVersion(version: unknown): CodexExtensionCompatibility {
    if (
        typeof version === 'string' &&
        SUPPORTED_CODEX_EXTENSION_VERSIONS.some((supportedVersion) => supportedVersion === version)
    ) {
        return {
            supported: true,
            version,
            detail: `openai.chatgpt ${version} is supported by the Aiflow official worker.`
        };
    }

    if (typeof version === 'string' && version.length > 0) {
        return {
            supported: false,
            version,
            detail:
                `Aiflow official worker is disabled for openai.chatgpt ${version}. ` +
                `Tested version: ${TESTED_CODEX_EXTENSION_VERSION}. ` +
                'Aiflow will use the legacy worker.'
        };
    }

    return {
        supported: false,
        detail:
            'Aiflow could not determine the installed openai.chatgpt version. ' +
            `Tested version: ${TESTED_CODEX_EXTENSION_VERSION}. ` +
            'Aiflow will use the legacy worker.'
    };
}

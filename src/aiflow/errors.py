class AiflowError(Exception):
    """Base exception for expected Aiflow failures."""


class GitError(AiflowError):
    """Raised when a required Git operation fails."""


class ClipboardError(AiflowError):
    """Raised when clipboard access fails."""


class PacketError(AiflowError):
    """Raised when an Aiflow packet is malformed or invalid."""


class StateError(AiflowError):
    """Raised when local task or project state is inconsistent."""

// EFFECTIVE-365 slice: stage 4 (Track) of the publisher co-pilot.
//
// Logs what got driven, where, and when (per PUBLISHER.md's launch-report
// job), and holds incoming replies so Jeff can answer as himself. This
// module never answers a reply on Jeff's behalf — surfacing is as far as
// automation goes, matching the operator-approval boundary the whole
// co-pilot is built around.

import type { DriveResult } from './drive.ts';

export interface TrackedLaunch {
  readonly draftId: string;
  readonly platformId: string;
  readonly mode: 'drive' | 'fill_and_stop';
  readonly posted: boolean;
  readonly trackedAt: string;
}

export interface Reply {
  readonly draftId: string;
  readonly platformId: string;
  readonly author: string;
  readonly body: string;
  readonly receivedAt: string;
  answered: boolean;
}

/** Append-only log of what got driven, where, and when. */
export class LaunchTracker {
  private readonly launches: TrackedLaunch[] = [];
  private readonly replies: Reply[] = [];

  /** Records a drive() result. `at` is caller-supplied so tests stay deterministic. */
  record(result: DriveResult, at: string): TrackedLaunch {
    const entry: TrackedLaunch = {
      draftId: result.draftId,
      platformId: result.platformId,
      mode: result.mode,
      posted: result.posted,
      trackedAt: at,
    };
    this.launches.push(entry);
    return entry;
  }

  /** Surfaces an incoming reply for Jeff to answer as himself — never auto-answered. */
  surfaceReply(reply: Omit<Reply, 'answered'>): Reply {
    const entry: Reply = { ...reply, answered: false };
    this.replies.push(entry);
    return entry;
  }

  /** Jeff has answered a surfaced reply himself; marks it so it stops surfacing as pending. */
  markAnswered(draftId: string, author: string): Reply {
    const reply = this.replies.find((r) => r.draftId === draftId && r.author === author && !r.answered);
    if (!reply) {
      throw new Error(`no pending reply from "${author}" on draft "${draftId}"`);
    }
    reply.answered = true;
    return reply;
  }

  launchReport(): readonly TrackedLaunch[] {
    return [...this.launches];
  }

  /** Replies still waiting on Jeff — the only queue this stage ever produces work for. */
  pendingReplies(): readonly Reply[] {
    return this.replies.filter((r) => !r.answered);
  }
}

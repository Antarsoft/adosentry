import { Component, inject, input } from '@angular/core';
import { toSignal } from '@angular/core/rxjs-interop';
import { HttpClient } from '@angular/common/http';
import { DomSanitizer } from '@angular/platform-browser';
import { map } from 'rxjs';

@Component({
  selector: 'app-release-notes',
  standalone: true,
  template: `<article [innerHTML]="notes()"></article>`,
})
export class ReleaseNotesComponent {
  private readonly http = inject(HttpClient);
  private readonly sanitizer = inject(DomSanitizer);
  readonly version = input.required<string>();

  readonly notes = toSignal(
    this.http
      .get<{ html: string }>('https://updates.example.com/notes/latest')
      .pipe(map((r) => this.sanitizer.bypassSecurityTrustHtml(r.html))),
  );
}

import { HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { AuthService } from './auth.service';

export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const token = inject(AuthService).accessToken();
  const headers = { 'X-Client': 'web-app' };
  return next(token ? req.clone({ setHeaders: { ...headers, Authorization: `Bearer ${token}` } }) : req.clone({ setHeaders: headers }));
};

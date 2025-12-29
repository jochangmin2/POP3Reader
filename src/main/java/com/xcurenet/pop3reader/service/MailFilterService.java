package com.xcurenet.pop3reader.service;

import org.springframework.stereotype.Service;

import javax.mail.Message;
import javax.mail.MessagingException;

@Service
public class MailFilterService {

	public boolean isOriginalMail(Message msg) {
		try {
			if (hasHeader(msg, "In-Reply-To")) return false;
			if (hasHeader(msg, "References")) return false;
			if (hasHeader(msg, "Resent-From")) return false;
			if (hasHeader(msg, "Resent-To")) return false;

			String[] auto = msg.getHeader("Auto-Submitted");
			if (auto != null && !"no".equalsIgnoreCase(auto[0])) return false;

			String subject = msg.getSubject();
			if (subject != null) {
				String s = subject.toLowerCase();
				return !(s.startsWith("re:") || s.startsWith("fw:") || s.startsWith("fwd:") || s.startsWith("[re]") || s.startsWith("[fw]"));
			}
			return true;
		} catch (Exception e) {
			return false;
		}
	}

	private boolean hasHeader(Message msg, String name) throws MessagingException {
		String[] h = msg.getHeader(name);
		return h != null && h.length > 0;
	}
}
